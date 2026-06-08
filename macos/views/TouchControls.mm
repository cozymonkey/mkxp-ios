/*
 ** TouchControls.mm
 **
 ** iOS-only. A lightweight UIKit overlay (D-pad + A/B) drawn on top of SDL's
 ** GL view. Each button writes directly into EventThread::keyStates[] — the same
 ** array Input snapshots every frame — so the existing keybindings pipeline
 ** (arrows -> movement, Return -> C/Use, X -> B/Back/Menu) is fully reused.
 **
 ** This is the minimal control set to reach and start the game; a polished,
 ** configurable overlay is a later phase.
 */

#include <TargetConditionals.h>

#if TARGET_OS_IPHONE

#import <UIKit/UIKit.h>
#import <SDL.h>
#import <SDL_syswm.h>
#import <SDL_scancode.h>

#include "eventthread.h"

/* Overlay that only intercepts touches that land on a button; everything else
 * falls through to SDL's GL view underneath. */
@interface MKXPTouchOverlay : UIView
@end

@implementation MKXPTouchOverlay
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}
@end

@interface MKXPTouchControls : NSObject
@property (nonatomic, strong) MKXPTouchOverlay *overlay;
- (void)attachTo:(UIView *)parent;
@end

@implementation MKXPTouchControls

- (UIButton *)makeButton:(NSString *)title scancode:(int)sc {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.tag = sc;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    [b setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.9] forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.28];
    b.layer.cornerRadius = 8.0;
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.4].CGColor;
    [b addTarget:self action:@selector(press:) forControlEvents:UIControlEventTouchDown];
    [b addTarget:self action:@selector(press:) forControlEvents:UIControlEventTouchDragEnter];
    [b addTarget:self action:@selector(release:)
        forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside |
                         UIControlEventTouchCancel | UIControlEventTouchDragExit];
    return b;
}

- (void)press:(UIButton *)b {
    EventThread::keyStates[b.tag] = 1;
}

- (void)release:(UIButton *)b {
    EventThread::keyStates[b.tag] = 0;
}

- (void)attachTo:(UIView *)parent {
    CGRect bounds = parent.bounds;
    MKXPTouchOverlay *ov = [[MKXPTouchOverlay alloc] initWithFrame:bounds];
    ov.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    ov.backgroundColor = [UIColor clearColor];
    self.overlay = ov;

    const CGFloat S = 56;   // button size
    const CGFloat G = 6;    // gap
    const CGFloat M = 24;   // margin from screen edges
    CGFloat W = bounds.size.width;
    CGFloat H = bounds.size.height;

    /* D-pad (plus shape), bottom-left. Anchor on a center cross. */
    CGFloat cx = M + S + G + S / 2;            // center x of the cross
    CGFloat cy = H - M - S - G - S / 2;        // center y of the cross
    UIButton *up    = [self makeButton:@"▲" scancode:SDL_SCANCODE_UP];
    UIButton *down  = [self makeButton:@"▼" scancode:SDL_SCANCODE_DOWN];
    UIButton *left  = [self makeButton:@"◀" scancode:SDL_SCANCODE_LEFT];
    UIButton *right = [self makeButton:@"▶" scancode:SDL_SCANCODE_RIGHT];
    up.frame    = CGRectMake(cx - S/2, cy - S/2 - (S+G), S, S);
    down.frame  = CGRectMake(cx - S/2, cy - S/2 + (S+G), S, S);
    left.frame  = CGRectMake(cx - S/2 - (S+G), cy - S/2, S, S);
    right.frame = CGRectMake(cx - S/2 + (S+G), cy - S/2, S, S);
    up.autoresizingMask = down.autoresizingMask = left.autoresizingMask =
        right.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleRightMargin;

    /* A (Use/Return) + B (Back-Menu/X), bottom-right. */
    UIButton *a = [self makeButton:@"A" scancode:SDL_SCANCODE_RETURN];
    UIButton *b = [self makeButton:@"B" scancode:SDL_SCANCODE_X];
    a.frame = CGRectMake(W - M - S, H - M - S - (S/2), S, S);          // lower
    b.frame = CGRectMake(W - M - S - (S+G) - (S/2), H - M - S, S, S);  // left of A
    a.autoresizingMask = b.autoresizingMask =
        UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleLeftMargin;

    for (UIButton *btn in @[up, down, left, right, a, b])
        [ov addSubview:btn];

    [parent addSubview:ov];
}

@end

static MKXPTouchControls *g_touchControls = nil;

extern "C" void mkxp_ios_initTouchControls(SDL_Window *win) {
    /* SDL runs SDL_main (the engine's main) on a secondary thread on iOS, so this
     * is NOT the UIKit main thread. All UIKit access — including reading the
     * window/view from SDL — must happen on the main queue. */
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            SDL_SysWMinfo info;
            SDL_VERSION(&info.version);
            if (!SDL_GetWindowWMInfo(win, &info))
                return;

            UIWindow *uiwin = info.info.uikit.window;
            UIView *root = uiwin.rootViewController.view ?: uiwin;
            if (root == nil)
                return;

            if (g_touchControls == nil)
                g_touchControls = [[MKXPTouchControls alloc] init];

            [g_touchControls attachTo:root];
        }
    });
}

#endif
