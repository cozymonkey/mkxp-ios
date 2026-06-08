/*
 ** audiosession-ios.mm
 **
 ** iOS-only. Configures an AVAudioSession before OpenAL (OpenAL-soft on iOS
 ** routes through CoreAudio, which needs an active audio session). Must be
 ** called before alcOpenDevice().
 */

#include <TargetConditionals.h>

#if TARGET_OS_IPHONE

#import <AVFoundation/AVFoundation.h>

extern "C" void mkxp_ios_initAudioSession(void) {
    @autoreleasepool {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSError *err = nil;

        /* Playback: game audio is audible regardless of the ring/silent switch,
         * which is what players expect from a game. Switch to
         * AVAudioSessionCategoryAmbient if you'd rather respect the silent
         * switch and mix with other apps. */
        if (![session setCategory:AVAudioSessionCategoryPlayback error:&err])
            NSLog(@"mkxp-z: AVAudioSession setCategory failed: %@", err);

        if (![session setActive:YES error:&err])
            NSLog(@"mkxp-z: AVAudioSession setActive failed: %@", err);
    }
}

#endif
