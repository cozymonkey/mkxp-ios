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

/* A single slidable 4-way D-pad. Tracks one finger and picks the dominant axis
 * from the touch position, so you can roll/slide between directions without
 * lifting (separate buttons can't, due to UIKit touch ownership). */
@interface MKXPDPad : UIView
@end

@implementation MKXPDPad {
    int _active; // currently-held SDL scancode, or 0
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _active = 0;
        self.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.28];
        self.layer.cornerRadius = 12;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.4].CGColor;

        NSArray *arrows = @[@"▲", @"▼", @"◀", @"▶"];
        CGFloat w = frame.size.width, h = frame.size.height, s = 36, e = 26;
        CGPoint centers[4] = {
            CGPointMake(w/2, e + s/2),       // up
            CGPointMake(w/2, h - e - s/2),   // down
            CGPointMake(e + s/2, h/2),       // left
            CGPointMake(w - e - s/2, h/2)    // right
        };
        for (int i = 0; i < 4; i++) {
            UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, s, s)];
            l.text = arrows[i];
            l.font = [UIFont boldSystemFontOfSize:24];
            l.textColor = [UIColor colorWithWhite:1.0 alpha:0.9];
            l.textAlignment = NSTextAlignmentCenter;
            l.center = centers[i];
            l.userInteractionEnabled = NO;
            [self addSubview:l];
        }
    }
    return self;
}

- (void)hold:(int)sc {
    if (sc == _active) return;
    if (_active) EventThread::keyStates[_active] = 0;
    if (sc) EventThread::keyStates[sc] = 1;
    _active = sc;
}

- (void)track:(UITouch *)t {
    CGPoint p = [t locationInView:self];
    CGFloat cx = self.bounds.size.width / 2, cy = self.bounds.size.height / 2;
    CGFloat dx = p.x - cx, dy = p.y - cy;
    CGFloat dead = MIN(cx, cy) * 0.28;   // center dead zone
    int sc = 0;
    if (dx * dx + dy * dy >= dead * dead) {
        if (fabs(dx) > fabs(dy)) sc = (dx < 0) ? SDL_SCANCODE_LEFT : SDL_SCANCODE_RIGHT;
        else                     sc = (dy < 0) ? SDL_SCANCODE_UP   : SDL_SCANCODE_DOWN;
    }
    [self hold:sc];
}

- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self track:t.anyObject]; }
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self track:t.anyObject]; }
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self hold:0]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { [self hold:0]; }
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

    /* D-pad, bottom-left: a single slidable view (drag between directions). */
    CGFloat dp = 3 * S + 2 * G;
    MKXPDPad *dpad = [[MKXPDPad alloc] initWithFrame:CGRectMake(M, H - M - dp, dp, dp)];
    dpad.autoresizingMask = BL;
    [ov addSubview:dpad];

    /* Face buttons, bottom-right 2x2. Labelled with the keyboard key the game
     * documents (A=Use=C, B=Back=X, Bag=Z, Special=D). */
    CGFloat rcx = W - M - S;            // right column x
    CGFloat lcx = W - M - S - (S+G);    // left column x
    CGFloat brY = H - M - S;            // bottom row y
    CGFloat trY = H - M - S - (S+G);    // top row y
    [self button:@"C" scancode:SDL_SCANCODE_C frame:CGRectMake(rcx, brY, S, S) mask:BR];  // A/Use
    [self button:@"X" scancode:SDL_SCANCODE_X frame:CGRectMake(lcx, brY, S, S) mask:BR];  // B/Back
    [self button:@"Z" scancode:SDL_SCANCODE_Z frame:CGRectMake(rcx, trY, S, S) mask:BR];  // Bag
    [self button:@"D" scancode:SDL_SCANCODE_D frame:CGRectMake(lcx, trY, S, S) mask:BR];  // Special

    /* Shoulders + speed, top (keyboard keys: L=A, R=S, speed=Q). */
    [self button:@"A" scancode:SDL_SCANCODE_A frame:CGRectMake(M,                 M, S, S) mask:TL];  // L
    [self button:@"S" scancode:SDL_SCANCODE_S frame:CGRectMake(W - M - S,         M, S, S) mask:TR];  // R
    [self button:@"Q" scancode:SDL_SCANCODE_Q frame:CGRectMake(W - M - S - (S+G), M, S, S) mask:TR];  // speed

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
