//
//  systemImplApple.m
//  Player
//
//  Created by ゾロアーク on 11/22/20.
//

#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#import <AppKit/AppKit.h>
#import "SettingsMenuController.h"
#endif
#import <Metal/Metal.h>

#import <sys/sysctl.h>
#import "system.h"

std::string systemImpl::getSystemLanguage() {
    @autoreleasepool {
        NSString *languageCode = NSLocale.currentLocale.languageCode;
        NSString *countryCode = NSLocale.currentLocale.countryCode;
        return std::string([NSString stringWithFormat:@"%@_%@", languageCode, countryCode].UTF8String);
    }
}

std::string systemImpl::getUserName() {
    @autoreleasepool {
#if TARGET_OS_IPHONE
        return std::string(UIDevice.currentDevice.name.UTF8String);
#else
        return std::string(NSUserName().UTF8String);
#endif
    }
}

int systemImpl::getScalingFactor() {
#if TARGET_OS_IPHONE
    return (int)UIScreen.mainScreen.scale;
#else
    return NSApplication.sharedApplication.mainWindow.backingScaleFactor;
#endif
}

bool systemImpl::isWine() {
    return false;
}

bool systemImpl::isRosetta() {
    int translated = 0;
    size_t size = sizeof(translated);
    int result = sysctlbyname("sysctl.proc_translated", &translated, &size, NULL, 0);
    
    if (result == -1)
        return false;
    
    return translated;
}

systemImpl::WineHostType systemImpl::getRealHostType() {
    return WineHostType::Mac;
}


// constant, if it's not nil then just raise the menu instead
#if TARGET_OS_IPHONE
void openSettingsWindow() {
    /* No native settings UI on iOS yet. */
}
#else
SettingsMenu *smenu = nil;
void openSettingsWindow() {
    if (smenu == nil) {
        smenu = [SettingsMenu openWindow];
        return;
    }
    [smenu raise];
}
#endif

bool isMetalSupported() {
    if (@available(macOS 10.13.0, *)) {
        return MTLCreateSystemDefaultDevice() != nil;
    }
    return false;
}

std::string getPlistValue(const char *key) {
    @autoreleasepool {
        NSString *hash = [[NSBundle mainBundle] objectForInfoDictionaryKey:@(key)];
        if (hash != nil) {
            return std::string(hash.UTF8String);
        }
        return "";
    }
}
