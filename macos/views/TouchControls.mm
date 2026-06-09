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
    b.titleLabel.font = [UIFont boldSystemFontOfSize:26];
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

- (UIButton *)button:(NSString *)title scancode:(int)sc
               frame:(CGRect)frame mask:(UIViewAutoresizing)mask {
    UIButton *b = [self makeButton:title scancode:sc];
    b.frame = frame;
    b.autoresizingMask = mask;
    [self.overlay addSubview:b];
    return b;
}

- (void)attachTo:(UIView *)parent {
    CGRect bounds = parent.bounds;
    MKXPTouchOverlay *ov = [[MKXPTouchOverlay alloc] initWithFrame:bounds];
    ov.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    ov.backgroundColor = [UIColor clearColor];
    self.overlay = ov;

    const CGFloat S = 62;   // button size
    const CGFloat G = 8;    // gap
    const CGFloat M = 18;   // margin from screen edges
    const CGFloat W = bounds.size.width;
    const CGFloat H = bounds.size.height;

    const UIViewAutoresizing BL = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleRightMargin;  // bottom-left
    const UIViewAutoresizing BR = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleLeftMargin;   // bottom-right
    const UIViewAutoresizing TL = UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleRightMargin; // top-left
    const UIViewAutoresizing TR = UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleLeftMargin;  // top-right

    /* D-pad (plus), bottom-left. Mapping: arrow keys. */
    CGFloat cx = M + S + G + S / 2;
    CGFloat cy = H - M - S - G - S / 2;
    [self button:@"▲" scancode:SDL_SCANCODE_UP    frame:CGRectMake(cx - S/2,         cy - S/2 - (S+G), S, S) mask:BL];
    [self button:@"▼" scancode:SDL_SCANCODE_DOWN  frame:CGRectMake(cx - S/2,         cy - S/2 + (S+G), S, S) mask:BL];
    [self button:@"◀" scancode:SDL_SCANCODE_LEFT  frame:CGRectMake(cx - S/2 - (S+G), cy - S/2,         S, S) mask:BL];
    [self button:@"▶" scancode:SDL_SCANCODE_RIGHT frame:CGRectMake(cx - S/2 + (S+G), cy - S/2,         S, S) mask:BL];

    /* Face buttons, bottom-right 2x2.
     * A=Use(C), B=Back(X), Z=Bag(Z), 특수=Special(D). */
    CGFloat rcx = W - M - S;            // right column x
    CGFloat lcx = W - M - S - (S+G);    // left column x
    CGFloat brY = H - M - S;            // bottom row y
    CGFloat trY = H - M - S - (S+G);    // top row y
    [self button:@"A"  scancode:SDL_SCANCODE_C frame:CGRectMake(rcx, brY, S, S) mask:BR];
    [self button:@"B"  scancode:SDL_SCANCODE_X frame:CGRectMake(lcx, brY, S, S) mask:BR];
    [self button:@"Z"  scancode:SDL_SCANCODE_Z frame:CGRectMake(rcx, trY, S, S) mask:BR];
    [self button:@"특" scancode:SDL_SCANCODE_D frame:CGRectMake(lcx, trY, S, S) mask:BR];  // 특수

    /* Shoulders + speed, top. L=A, R=S, 배속=Q. */
    [self button:@"L"  scancode:SDL_SCANCODE_A frame:CGRectMake(M,                 M, S, S) mask:TL];
    [self button:@"R"  scancode:SDL_SCANCODE_S frame:CGRectMake(W - M - S,         M, S, S) mask:TR];
    [self button:@"배" scancode:SDL_SCANCODE_Q frame:CGRectMake(W - M - S - (S+G), M, S, S) mask:TR];  // 배속

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
