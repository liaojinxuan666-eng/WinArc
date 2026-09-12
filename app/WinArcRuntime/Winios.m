/*
 * Winios.m — minimal WinArc iOS Wine compositor.
 *
 * This is intentionally the small subset required for the first visible
 * Wine desktop:
 *   user32/win32u window lifecycle
 *   GDI BGRA surfaces -> Core Animation
 *   per-HWND CAMetalLayer for future DXMT swapchains
 *
 * Diagnostic/freeze probes and title-specific Madeira code are not carried
 * into WinArc.
 */

#import "Winios.h"

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef void *HWND;
typedef void *HCURSOR;

static __weak UIView *g_parent_view;
static UIView *g_compositor_view;
static CALayer *g_desktop_background;

static NSMutableDictionary<NSNumber *, CALayer *> *g_window_layers;
static NSMutableDictionary<NSNumber *, NSValue *> *g_window_rects;
static NSMutableDictionary<NSNumber *, NSValue *> *g_client_rects;
static NSMutableDictionary<NSNumber *, CAMetalLayer *> *g_metal_layers;

static int g_desktop_width = 1280;
static int g_desktop_height = 720;
static CGFloat g_screen_scale = 1.0;

static CGRect g_compositor_frame;
static BOOL g_has_explicit_frame = NO;

static CGFloat g_px_to_pt = 1.0;
static CGPoint g_desktop_origin;

static NSNumber *winios_key(HWND hwnd)
{
    return @((uintptr_t)hwnd);
}

static void winios_assert_main(void)
{
    NSCAssert([NSThread isMainThread], @"Winios compositor must mutate UIKit on main thread");
}

static void winios_recalculate_transform(void)
{
    if (!g_compositor_view) return;

    CGRect bounds = g_compositor_view.bounds;

    CGFloat sx = bounds.size.width / MAX((CGFloat)g_desktop_width, 1.0);
    CGFloat sy = bounds.size.height / MAX((CGFloat)g_desktop_height, 1.0);

    g_px_to_pt = MIN(sx, sy);

    CGFloat desktop_w = g_desktop_width * g_px_to_pt;
    CGFloat desktop_h = g_desktop_height * g_px_to_pt;

    g_desktop_origin = CGPointMake(
        floor((bounds.size.width - desktop_w) * 0.5),
        floor((bounds.size.height - desktop_h) * 0.5)
    );

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    g_desktop_background.frame = CGRectMake(
        g_desktop_origin.x,
        g_desktop_origin.y,
        desktop_w,
        desktop_h
    );

    for (NSNumber *key in g_window_layers)
    {
        CALayer *layer = g_window_layers[key];
        CGRect pixel_rect = [g_window_rects[key] CGRectValue];

        layer.frame = CGRectMake(
            g_desktop_origin.x + pixel_rect.origin.x * g_px_to_pt,
            g_desktop_origin.y + pixel_rect.origin.y * g_px_to_pt,
            pixel_rect.size.width * g_px_to_pt,
            pixel_rect.size.height * g_px_to_pt
        );

        CAMetalLayer *metal = g_metal_layers[key];
        NSValue *client_value = g_client_rects[key];

        if (metal && client_value)
        {
            CGRect client = client_value.CGRectValue;

            metal.frame = CGRectMake(
                (client.origin.x - pixel_rect.origin.x) * g_px_to_pt,
                (client.origin.y - pixel_rect.origin.y) * g_px_to_pt,
                client.size.width * g_px_to_pt,
                client.size.height * g_px_to_pt
            );

            metal.contentsScale = g_screen_scale;
            metal.drawableSize = CGSizeMake(
                MAX(client.size.width, 1.0),
                MAX(client.size.height, 1.0)
            );
        }
    }

    [CATransaction commit];
}

static void winios_ensure_compositor(void)
{
    winios_assert_main();

    UIView *parent = g_parent_view;
    if (!parent) return;

    if (!g_compositor_view)
    {
        g_window_layers = [NSMutableDictionary new];
        g_window_rects = [NSMutableDictionary new];
        g_client_rects = [NSMutableDictionary new];
        g_metal_layers = [NSMutableDictionary new];

        g_compositor_view = [[UIView alloc] initWithFrame:parent.bounds];
        g_compositor_view.userInteractionEnabled = NO;
        g_compositor_view.clipsToBounds = YES;
        g_compositor_view.backgroundColor =
            [UIColor colorWithWhite:0.035 alpha:1.0];

        g_desktop_background = [CALayer layer];
        g_desktop_background.backgroundColor =
            [UIColor colorWithRed:0.0
                            green:0.40
                             blue:0.40
                            alpha:1.0].CGColor;
        g_desktop_background.anchorPoint = CGPointZero;

        [g_compositor_view.layer addSublayer:g_desktop_background];
        [parent addSubview:g_compositor_view];
    }

    g_compositor_view.frame =
        g_has_explicit_frame ? g_compositor_frame : parent.bounds;

    winios_recalculate_transform();
}

static CALayer *winios_layer_for(HWND hwnd, BOOL create)
{
    winios_assert_main();
    winios_ensure_compositor();

    if (!g_compositor_view) return nil;

    NSNumber *key = winios_key(hwnd);
    CALayer *layer = g_window_layers[key];

    if (!layer && create)
    {
        layer = [CALayer layer];
        layer.anchorPoint = CGPointZero;
        layer.magnificationFilter = kCAFilterNearest;
        layer.minificationFilter = kCAFilterLinear;
        layer.opaque = YES;
        layer.actions = @{
            @"position": [NSNull null],
            @"bounds": [NSNull null],
            @"contents": [NSNull null],
            @"hidden": [NSNull null]
        };

        g_window_layers[key] = layer;
        [g_compositor_view.layer addSublayer:layer];
    }

    return layer;
}

void winios_init(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        winios_ensure_compositor();
    });
}

void winios_attach_compositor(UIView *parent)
{
    if (!parent) return;

    void (^attach)(void) = ^{
        if (g_parent_view != parent)
        {
            [g_compositor_view removeFromSuperview];
            g_compositor_view = nil;
            g_desktop_background = nil;
            g_window_layers = nil;
            g_window_rects = nil;
            g_client_rects = nil;
            g_metal_layers = nil;
        }

        g_parent_view = parent;
        winios_ensure_compositor();
    };

    if ([NSThread isMainThread])
        attach();
    else
        dispatch_async(dispatch_get_main_queue(), attach);
}

void winios_set_compositor_frame(CGRect frame)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        g_compositor_frame = frame;
        g_has_explicit_frame = YES;

        if (g_compositor_view)
        {
            g_compositor_view.frame = frame;
            winios_recalculate_transform();
        }
    });
}

void winios_set_screen_size(int width_px, int height_px, CGFloat screen_scale)
{
    if (width_px <= 0 || height_px <= 0) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        g_desktop_width = width_px;
        g_desktop_height = height_px;
        g_screen_scale = MAX(screen_scale, 1.0);
        winios_recalculate_transform();
    });
}

CALayer *winios_desktop_layer(void)
{
    __block CALayer *result = nil;

    void (^read)(void) = ^{
        winios_ensure_compositor();
        result = g_desktop_background;
    };

    if ([NSThread isMainThread])
        read();
    else
        dispatch_sync(dispatch_get_main_queue(), read);

    return result;
}

CALayer *winios_window_layer_for_hwnd(void *hwnd)
{
    __block CALayer *result = nil;

    void (^read)(void) = ^{
        result = winios_layer_for(hwnd, YES);
    };

    if ([NSThread isMainThread])
        read();
    else
        dispatch_sync(dispatch_get_main_queue(), read);

    return result;
}

CAMetalLayer *winios_metal_layer_for_hwnd(void *hwnd)
{
    __block CAMetalLayer *result = nil;

    void (^make)(void) = ^{
        CALayer *window = winios_layer_for(hwnd, YES);
        if (!window) return;

        NSNumber *key = winios_key(hwnd);
        CAMetalLayer *metal = g_metal_layers[key];

        if (!metal)
        {
            metal = [CAMetalLayer layer];
            metal.anchorPoint = CGPointZero;
            metal.device = MTLCreateSystemDefaultDevice();
            metal.pixelFormat = MTLPixelFormatBGRA8Unorm;
            metal.framebufferOnly = YES;
            metal.opaque = YES;
            metal.maximumDrawableCount = 2;

            g_metal_layers[key] = metal;
            [window addSublayer:metal];

            CGRect window_rect = [g_window_rects[key] CGRectValue];
            NSValue *client_value = g_client_rects[key];

            if (client_value)
            {
                CGRect client = client_value.CGRectValue;

                metal.frame = CGRectMake(
                    (client.origin.x - window_rect.origin.x) * g_px_to_pt,
                    (client.origin.y - window_rect.origin.y) * g_px_to_pt,
                    client.size.width * g_px_to_pt,
                    client.size.height * g_px_to_pt
                );

                metal.drawableSize = CGSizeMake(
                    MAX(client.size.width, 1.0),
                    MAX(client.size.height, 1.0)
                );
            }
            else
            {
                metal.frame = window.bounds;
                metal.drawableSize = CGSizeMake(
                    MAX(window.bounds.size.width * g_screen_scale, 1.0),
                    MAX(window.bounds.size.height * g_screen_scale, 1.0)
                );
            }
        }

        result = metal;
    };

    if ([NSThread isMainThread])
        make();
    else
        dispatch_sync(dispatch_get_main_queue(), make);

    return result;
}

/* ------------------------------------------------------------------------- */
/* Wine driver exports                                                        */
/* ------------------------------------------------------------------------- */

int winios_pCreateWindow(void *hwnd)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        (void)winios_layer_for(hwnd, YES);
    });

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
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_window_layers) return;

        NSNumber *key = winios_key(hwnd);

        [g_metal_layers[key] removeFromSuperlayer];
        [g_window_layers[key] removeFromSuperlayer];

        [g_metal_layers removeObjectForKey:key];
        [g_client_rects removeObjectForKey:key];
        [g_window_rects removeObjectForKey:key];
        [g_window_layers removeObjectForKey:key];
    });
}

unsigned int winios_pShowWindow(void *hwnd,
                                int command,
                                void *rect,
                                unsigned int swp)
{
    (void)rect;
    (void)swp;

    dispatch_async(dispatch_get_main_queue(), ^{
        CALayer *layer = winios_layer_for(hwnd, YES);
        /* SW_HIDE is zero. Other commands are visible for this milestone. */
        layer.hidden = (command == 0);
    });

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

/*
 * Called by the iOS win32u shim with visible and client rectangles in desktop
 * pixels. This is the authoritative geometry path; pWindowPosChanged stays
 * opaque because the Apple target intentionally does not import Wine headers.
 */
void winios_window_frame(void *hwnd,
                         int x, int y, int w, int h, int visible,
                         int client_x, int client_y,
                         int client_w, int client_h)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        CALayer *layer = winios_layer_for(hwnd, YES);
        if (!layer) return;

        NSNumber *key = winios_key(hwnd);

        CGRect window_rect = CGRectMake(x, y, MAX(w, 1), MAX(h, 1));
        CGRect client_rect = CGRectMake(
            client_x,
            client_y,
            MAX(client_w, 1),
            MAX(client_h, 1)
        );

        g_window_rects[key] = [NSValue valueWithCGRect:window_rect];
        g_client_rects[key] = [NSValue valueWithCGRect:client_rect];

        [CATransaction begin];
        [CATransaction setDisableActions:YES];

        layer.frame = CGRectMake(
            g_desktop_origin.x + x * g_px_to_pt,
            g_desktop_origin.y + y * g_px_to_pt,
            MAX(w, 1) * g_px_to_pt,
            MAX(h, 1) * g_px_to_pt
        );
        layer.hidden = !visible;

        CAMetalLayer *metal = g_metal_layers[key];
        if (metal)
        {
            metal.frame = CGRectMake(
                (client_x - x) * g_px_to_pt,
                (client_y - y) * g_px_to_pt,
                MAX(client_w, 1) * g_px_to_pt,
                MAX(client_h, 1) * g_px_to_pt
            );
            metal.drawableSize = CGSizeMake(
                MAX(client_w, 1),
                MAX(client_h, 1)
            );
        }

        [CATransaction commit];
    });
}

/*
 * Copy immediately because Wine owns the source buffer only for this call.
 * The NSData object then safely crosses to the main queue.
 */
void winios_surface_present(void *hwnd,
                            int dirty_x, int dirty_y,
                            int dirty_w, int dirty_h,
                            int surface_w, int surface_h,
                            int stride,
                            const void *bits)
{
    (void)dirty_x;
    (void)dirty_y;
    (void)dirty_w;
    (void)dirty_h;

    if (!bits || surface_w <= 0 || surface_h <= 0 || stride <= 0)
        return;

    size_t bytes = (size_t)stride * (size_t)surface_h;
    NSData *data = [NSData dataWithBytes:bits length:bytes];

    dispatch_async(dispatch_get_main_queue(), ^{
        CALayer *layer = winios_layer_for(hwnd, YES);
        if (!layer) return;

        CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
        CGDataProviderRef provider =
            CGDataProviderCreateWithCFData((__bridge CFDataRef)data);

        CGImageRef image = CGImageCreate(
            surface_w,
            surface_h,
            8,
            32,
            stride,
            color_space,
            kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst,
            provider,
            NULL,
            false,
            kCGRenderingIntentDefault
        );

        if (image)
        {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];

            layer.contents = (__bridge id)image;
            layer.contentsScale = 1.0;
            layer.contentsGravity = kCAGravityResize;

            if (CGRectIsEmpty(layer.frame))
            {
                NSNumber *key = winios_key(hwnd);

                g_window_rects[key] =
                    [NSValue valueWithCGRect:
                        CGRectMake(0, 0, surface_w, surface_h)];

                layer.frame = CGRectMake(
                    g_desktop_origin.x,
                    g_desktop_origin.y,
                    surface_w * g_px_to_pt,
                    surface_h * g_px_to_pt
                );
            }

            [CATransaction commit];
            CGImageRelease(image);
        }

        CGDataProviderRelease(provider);
        CGColorSpaceRelease(color_space);
    });
}

void winios_cursor_set(unsigned int id,
                       int w, int h,
                       int hot_x, int hot_y,
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
    if (name && *name)
        fprintf(stderr, "[WinArc/Winios] phase: %s\n", name);
}
