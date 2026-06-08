//
//  filesystemImplApple.mm
//  Player
//
//  Created by ゾロアーク on 11/21/20.
//

#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#import <AppKit/AppKit.h>
#endif
#import <SDL_syswm.h>

#import <SDL_filesystem.h>

#import "filesystemImpl.h"
#import "util/exception.h"

#define PATHTONS(str) [NSFileManager.defaultManager stringWithFileSystemRepresentation:str length:strlen(str)]

#define NSTOPATH(str) [NSFileManager.defaultManager fileSystemRepresentationWithPath:str]

bool filesystemImpl::fileExists(const char *path) {
    @autoreleasepool{
        BOOL isDir;
        return  [NSFileManager.defaultManager fileExistsAtPath:PATHTONS(path) isDirectory: &isDir] && !isDir;
    }
}



std::string filesystemImpl::contentsOfFileAsString(const char *path) {
    @autoreleasepool {
        NSString *fileContents = [NSString stringWithContentsOfFile: PATHTONS(path)];
        if (fileContents == nil)
            throw Exception(Exception::NoFileError, "Failed to read file at %s", path);
        
        return std::string(fileContents.UTF8String);
    }
}


bool filesystemImpl::setCurrentDirectory(const char *path) {
    @autoreleasepool {
        return [NSFileManager.defaultManager changeCurrentDirectoryPath: PATHTONS(path)];
    }
}

std::string filesystemImpl::getCurrentDirectory() {
    @autoreleasepool {
        return std::string(NSTOPATH(NSFileManager.defaultManager.currentDirectoryPath));
    }
}

std::string filesystemImpl::normalizePath(const char *path, bool preferred, bool absolute) {
    @autoreleasepool {
#if TARGET_OS_IPHONE
        /* PhysFS works with mount-relative paths. URLByStandardizingPath would
         * absolutize the path, and because getcwd resolves the iOS /private
         * symlink while standardizing does not, the cwd-prefix strip then fails
         * and an absolute path leaks out that PhysFS can't match. For a relative
         * input we just clean the separators and keep it relative. */
        if (!absolute && path[0] != '/') {
            NSString *p = [PATHTONS(path) stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
            while ([p hasPrefix:@"./"])
                p = [p substringFromIndex:2];
            return std::string(NSTOPATH(p));
        }
#endif
        NSString *nspath = [NSURL fileURLWithPath: PATHTONS(path)].URLByStandardizingPath.path;
        NSString *pwd = [NSString stringWithFormat:@"%@/", NSFileManager.defaultManager.currentDirectoryPath];
        if (!absolute) {
            nspath = [nspath stringByReplacingOccurrencesOfString:pwd withString:@""];
        }
        nspath = [nspath stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        return std::string(NSTOPATH(nspath));
    }
}

#if TARGET_OS_IPHONE
/* On iOS the app bundle is read-only and code-signed. The game ships as a blue
 * folder reference at <App>.app/game; on first launch (or after an app update)
 * we copy it into Documents/game so the game directory is writable and the
 * engine can run from a normal mutable path. Subsequent launches skip the copy
 * via a version marker.
 *
 * NOTE: the copy is synchronous on the SDL_main thread. SDL schedules SDL_main
 * after didFinishLaunching returns, so the strict launch watchdog is already
 * satisfied, but a very large first-launch copy still blocks the UI. If a device
 * kills the app on first launch, move this onto a background thread with a
 * loading indicator. */
std::string filesystemImpl::getDefaultGameRoot() {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *destGame = [docs stringByAppendingPathComponent:@"game"];
        NSString *srcGame = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"game"];
        NSString *marker = [destGame stringByAppendingPathComponent:@".mkxp_bundle_version"];
        NSString *bundleVer = NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"0";

        NSString *existing = [NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:nil];
        BOOL haveDest = [fm fileExistsAtPath:destGame];
        BOOL needCopy = !haveDest || ![existing isEqualToString:bundleVer];

        if (needCopy && [fm fileExistsAtPath:srcGame]) {
            if (haveDest)
                [fm removeItemAtPath:destGame error:nil];
            NSError *err = nil;
            if (![fm copyItemAtPath:srcGame toPath:destGame error:&err])
                NSLog(@"mkxp-z: failed to copy game assets to Documents: %@", err);
            else
                [bundleVer writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        return std::string(NSTOPATH(destGame));
    }
}
#else
std::string filesystemImpl::getDefaultGameRoot() {
    @autoreleasepool {
        NSString *p = [NSString stringWithFormat: @"%@/%s", NSBundle.mainBundle.bundlePath, "Contents/Game"];
        return std::string(NSTOPATH(p));
    }
}
#endif

NSString *getPathForAsset_internal(const char *baseName, const char *ext) {
    NSBundle *assetBundle = [NSBundle bundleWithPath:
                             [NSString stringWithFormat:
                              @"%@/%s",
                              NSBundle.mainBundle.resourcePath,
                              "Assets.bundle"
                             ]
                            ];
    
    if (assetBundle == nil)
        return nil;
    
    return [assetBundle pathForResource: @(baseName) ofType: @(ext)];
}

std::string filesystemImpl::getPathForAsset(const char *baseName, const char *ext) {
    @autoreleasepool {
        NSString *assetPath = getPathForAsset_internal(baseName, ext);
        if (assetPath == nil)
            throw Exception(Exception::NoFileError, "Failed to find the asset named %s.%s", baseName, ext);
        
        return std::string(NSTOPATH(getPathForAsset_internal(baseName, ext)));
    }
}

std::string filesystemImpl::contentsOfAssetAsString(const char *baseName, const char *ext) {
    @autoreleasepool {
        NSString *path = getPathForAsset_internal(baseName, ext);
        NSString *fileContents = [NSString stringWithContentsOfFile: path];
        
        // This should never fail
        if (fileContents == nil)
            throw Exception(Exception::MKXPError, "Failed to read file at %s", path.UTF8String);
        
        return std::string(fileContents.UTF8String);
    }
}

std::string filesystemImpl::getResourcePath() {
    @autoreleasepool {
        return std::string(NSTOPATH(NSBundle.mainBundle.resourcePath));
    }
}

std::string filesystemImpl::selectPath(SDL_Window *win, const char *msg, const char *prompt) {
#if TARGET_OS_IPHONE
    /* No folder picker on iOS; the game always runs from Documents/game. */
    (void)win; (void)msg; (void)prompt;
    return std::string();
#else
    @autoreleasepool {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.canChooseDirectories = true;
        panel.canChooseFiles = false;
        
        if (msg) panel.message = @(msg);
        if (prompt) panel.prompt = @(prompt);
        //panel.directoryURL = [NSURL fileURLWithPath:NSFileManager.defaultManager.currentDirectoryPath];
        
        SDL_SysWMinfo windowinfo{};
        SDL_GetWindowWMInfo(win, &windowinfo);
        
        [panel beginSheetModalForWindow:windowinfo.info.cocoa.window completionHandler:^(NSModalResponse res){
            [NSApp stopModalWithCode:res];
        }];
        
        [NSApp runModalForWindow:windowinfo.info.cocoa.window];
        
        // The window needs to be brought to the front again after the OpenPanel closes
        [windowinfo.info.cocoa.window makeKeyAndOrderFront:nil];
        if (panel.URLs.count > 0)
            return std::string(NSTOPATH(panel.URLs[0].path));

        return std::string();
    }
#endif
}
