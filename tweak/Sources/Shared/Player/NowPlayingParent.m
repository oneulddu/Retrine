// Tells MediaRemote which app the lock screen's now playing card belongs to, so that a tap on it opens this
// app when the Bundle ID in Info.plist and the signed application-identifier differ (a re-signed IPA).
//
// What it does, and only this: once at launch, and again each time the app becomes active, it asks
// MediaRemote to take the app's own CFBundleIdentifier, read from the Info.plist on disk, as the parent
// application of the local origin. It runs after Spotify's setter has finished, so the song info is never
// touched, and a failure of any step leaves playback and now playing exactly as they were.
//
// Adapted from BitChord-iOS 1.0.3 (App/BitChord/ProxyNative/BitChordNowPlayingFix.m, GPL-3.0, as is Retrine):
// the two MediaRemote functions, their loading with dlopen/dlsym, and the Info.plist identifier. Not taken
// from it: its CFBundleExecutable check, its initialization, and its three triggers. Here the trigger is
// SGNowPlayingInfoDidChangeNotification plus activation, gated by a dirty flag so a lyrics line or an extras
// resend never calls MediaRemote.
//
// Connection points (a change in either shows here, not as a silent loss of the fix):
//   - SGNowPlayingInfoDidChangeNotification, from Shared/Player/NowPlayingExtras.h. Its constant is linked, so
//     if it goes the build fails here.
//   - MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo, read only while the flag is dirty.
//
// Key: spotifyglass.nowplaying.parent (default on, read at launch, no row in Mod Settings). Off, nothing is
// installed and nothing is ever unbound: a switch takes effect at the next launch.
//
// MRMediaRemoteSetParentApplication returns void: a call means "requested", never "granted".
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import "Core/SGCore.h"
#import "Shared/Player/NowPlayingExtras.h"

#define SGKeyNowPlayingParent @"spotifyglass.nowplaying.parent"

// The ABI WebKit's MediaRemoteSoftLink.h declares. The origin is owned by MediaRemote: never released here.
typedef CFTypeRef (*SGMRGetLocalOrigin)(void);
typedef void (*SGMRSetParentApplication)(CFTypeRef origin, CFStringRef bundleID);

static SGMRGetLocalOrigin sg_getOrigin;
static SGMRSetParentApplication sg_setParent;
static NSString *sg_parentID;       // CFBundleIdentifier from the Info.plist on disk
// Main thread only, as everything below runs there.
static BOOL sg_dirty = YES;
static BOOL sg_failed;              // an exception, or a call that cannot be made: no more calls
static BOOL sg_loggedWaiting, sg_loggedNoOrigin, sg_loggedSigning;
static unsigned sg_requests;

// The running process is the app, not one of its extensions, which have their own Info.plist and
// NSExtension key. The executable's name is not used: it differs in some installs.
static BOOL runningAsApp(void) {
    NSBundle *main = NSBundle.mainBundle;
    return [main.bundlePath.pathExtension isEqualToString:@"app"] && !main.infoDictionary[@"NSExtension"];
}

static NSString *plistBundleID(void) {
    NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Info.plist"];
    id value = [NSDictionary dictionaryWithContentsOfFile:path][@"CFBundleIdentifier"];
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

// For the log only: the signed application-identifier next to the Info.plist's. The value reads
// "<prefix>.<id>", where the prefix is the App ID prefix (usually the Team ID, not always) and the id can be
// a wildcard; it is split at the first dot and nothing else is assumed. It never decides a call.
static void logSigning(void) {
    if (sg_loggedSigning) return;
    sg_loggedSigning = YES;
    void *security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
    CFTypeRef (*create)(CFAllocatorRef) = security ? dlsym(security, "SecTaskCreateFromSelf") : NULL;
    CFTypeRef (*copy)(CFTypeRef, CFStringRef, CFErrorRef *) = security ? dlsym(security, "SecTaskCopyValueForEntitlement") : NULL;
    if (!create || !copy) {
        SGLog(@"nowplaying: parent %@, signed application-identifier unreadable (no Security symbols)", sg_parentID);
        return;
    }
    CFTypeRef task = create(kCFAllocatorDefault);
    CFTypeRef raw = task ? copy(task, CFSTR("application-identifier"), NULL) : NULL;
    NSString *signedID = [(__bridge id)raw isKindOfClass:NSString.class] ? (__bridge NSString *)raw : nil;
    NSRange dot = [signedID rangeOfString:@"."];
    NSString *suffix = dot.location == NSNotFound ? signedID : [signedID substringFromIndex:NSMaxRange(dot)];
    SGLog(@"nowplaying: parent %@, signed application-identifier %@ (%@)", sg_parentID, signedID ?: @"unreadable",
          !signedID ? @"unknown" : [suffix isEqualToString:sg_parentID] ? @"same id" : [suffix isEqualToString:@"*"] ? @"wildcard" : @"differs");
    if (raw) CFRelease(raw);
    if (task) CFRelease(task);
}

static BOOL loadMediaRemote(void) {
    // The handle stays open for the life of the process.
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY | RTLD_LOCAL);
    if (handle) {
        sg_getOrigin = dlsym(handle, "MRMediaRemoteGetLocalOrigin");
        sg_setParent = dlsym(handle, "MRMediaRemoteSetParentApplication");
    }
    if (sg_getOrigin && sg_setParent) return YES;
    SGLog(@"nowplaying: MediaRemote %@ not found, parent application is left alone", handle ? @"functions" : @"framework");
    return NO;
}

static void tryBind(void) {
    if (!sg_dirty || sg_failed) return;
    if (![MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo count]) {
        if (!sg_loggedWaiting) SGLog(@"nowplaying: no now playing info yet, waiting");
        sg_loggedWaiting = YES;
        return;
    }
    @try {
        CFTypeRef origin = sg_getOrigin();
        if (!origin) {
            if (!sg_loggedNoOrigin) SGLog(@"nowplaying: no local origin yet, waiting");
            sg_loggedNoOrigin = YES;
            return;
        }
        sg_setParent(origin, (__bridge CFStringRef)sg_parentID);
    } @catch (NSException *exception) {
        sg_failed = YES;
        SGLog(@"nowplaying: parent request raised %@, no more requests", exception.name);
        return;
    }
    sg_dirty = NO;
    if (++sg_requests <= 5) SGLog(@"nowplaying: parent application requested for %@ (request %u)", sg_parentID, sg_requests);
    logSigning();
}

static void onMain(void (^block)(void)) {
    if (NSThread.isMainThread) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

__attribute__((constructor)) static void installParent(void) {
    if (!SGFlag(SGKeyNowPlayingParent, YES) || !runningAsApp()) return;
    sg_parentID = plistBundleID();
    if (!sg_parentID || !loadMediaRemote()) return;
    // queue:nil, then main: both notifications are posted by whoever posts them, and main may be waiting on
    // Spotify's CoreThread at launch (AGENTS.md).
    [NSNotificationCenter.defaultCenter addObserverForName:SGNowPlayingInfoDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        onMain(^{ tryBind(); });
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        onMain(^{
            sg_dirty = YES;
            tryBind();
        });
    }];
    // The first attempt, after the observers: info already there is bound at once, none keeps it dirty.
    dispatch_async(dispatch_get_main_queue(), ^{ tryBind(); });
}
