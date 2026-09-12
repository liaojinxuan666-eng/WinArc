#pragma once

#ifdef __OBJC__
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAMetalLayer.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

void winios_init(void);

#ifdef __OBJC__
void winios_attach_compositor(UIView *parent);
void winios_set_compositor_frame(CGRect frame);
void winios_set_screen_size(int width_px, int height_px, CGFloat screen_scale);
CALayer *winios_desktop_layer(void);
CALayer *winios_window_layer_for_hwnd(void *hwnd);
CAMetalLayer *winios_metal_layer_for_hwnd(void *hwnd);
#endif

#ifdef __cplusplus
}
#endif
