#import "SFApp.h"

NSString *SFRefPrefix(NSString *ref) {
    NSRange c = [ref rangeOfString:@":"];
    return c.location == NSNotFound ? nil : [ref substringToIndex:c.location];
}
NSString *SFRefID(NSString *ref) {
    NSRange c = [ref rangeOfString:@":"];
    return c.location == NSNotFound ? ref : [ref substringFromIndex:c.location + 1];
}

static BOOL channels(Class<SFApp> a) { return [a respondsToSelector:@selector(showsAreChannels)] && [a showsAreChannels]; }
BOOL SFShowRefIsChannel(NSString *ref) { return channels([SFAppRegistry appForRef:ref]); }
BOOL SFItemShowsAreChannels(SFItem *item) { return channels([SFAppRegistry appForItem:item]); }
BOOL SFSourceShowsAreChannels(NSString *source) { return channels([SFAppRegistry appNamed:source]); }
NSTimeInterval SFBackgroundPausedUntil(NSString *ref) {
    Class<SFApp> app = [SFAppRegistry appForRef:ref];
    return [app respondsToSelector:@selector(backgroundPausedUntil)] ? [app backgroundPausedUntil] : 0;
}
NSTimeInterval SFDownloadSpacing(NSString *ref) {
    Class<SFApp> app = [SFAppRegistry appForRef:ref];
    return [app respondsToSelector:@selector(downloadSpacing)] ? [app downloadSpacing] : 30;
}

@implementation SFAppRegistry

static NSMutableArray *gApps;
static NSMutableDictionary *gByName, *gByPrefix;

+ (void)registerApp:(Class)app {
    NSAssert([app conformsToProtocol:@protocol(SFApp)], @"%@ is no SFApp", app);
    if (!gApps) { gApps = [NSMutableArray new]; gByName = [NSMutableDictionary new]; gByPrefix = [NSMutableDictionary new]; }
    Class<SFApp> a = app;
    [gApps addObject:app];
    gByName[[a appIdentifier]] = app;
    for (NSString *p in [a refPrefixes]) {
        NSAssert(!gByPrefix[p], @"ref namespace %@ claimed twice", p);
        gByPrefix[p] = app;
    }
    // the theme of the app = base theme + the app's tokens (Framework knows no apps)
    [SFTheme registerTheme:[a appIdentifier] builder:^(SFTheme *t) { [a configureTheme:t]; }];
}

+ (NSArray *)apps { return [gApps copy] ?: @[]; }
+ (Class)appNamed:(NSString *)identifier { return identifier ? gByName[identifier] : nil; }
+ (Class)appForRef:(NSString *)ref { NSString *p = SFRefPrefix(ref); return p ? gByPrefix[p] : nil; }
+ (Class)appForItem:(SFItem *)item {
    if (!item) return nil;
    return [self appNamed:item.source] ?: [self appForRef:item.resolverRef] ?: [self appForRef:item.identifier];
}

+ (BOOL)isShowRef:(NSString *)ref {
    Class<SFApp> a = [self appForRef:ref];
    return a && [a respondsToSelector:@selector(showRefPrefixes)] && [[a showRefPrefixes] containsObject:SFRefPrefix(ref)];
}

+ (void)startAll { for (Class<SFApp> a in gApps) if ([a respondsToSelector:@selector(start)]) [a start]; }
+ (void)stopAll { for (Class<SFApp> a in gApps) if ([a respondsToSelector:@selector(stop)]) [a stop]; }

+ (void)startRemotesWithHost:(id<SFPlayerHost>)host {
    for (Class<SFApp> a in gApps) if ([a respondsToSelector:@selector(startRemoteWithHost:)]) [a startRemoteWithHost:host];
}
+ (void)stopRemotes { for (Class<SFApp> a in gApps) if ([a respondsToSelector:@selector(stopRemote)]) [a stopRemote]; }
+ (NSArray *)remoteStatusNotifications {
    NSMutableArray *r = [NSMutableArray new];
    for (Class<SFApp> a in gApps) if ([a respondsToSelector:@selector(remoteStatusNotification)]) [r addObject:[a remoteStatusNotification]];
    return r;
}
+ (NSString *)remoteStatusForTheme:(NSString *)themeID paused:(BOOL *)paused {
    Class<SFApp> own = [self appNamed:themeID];
    for (Class<SFApp> a in gApps) {
        if ((own && a != own) || ![a respondsToSelector:@selector(remoteStatus:)]) continue;
        BOOL p = NO;
        NSString *s = [a remoteStatus:&p];
        if (s) { if (paused) *paused = p; return s; }
    }
    return nil;
}
+ (BOOL)handleDevCommand:(NSString *)cmd arg:(NSString *)arg host:(id<SFPlayerHost>)host {
    for (Class<SFApp> a in gApps)
        if ([a respondsToSelector:@selector(handleDevCommand:arg:host:)] && [a handleDevCommand:cmd arg:arg host:host]) return YES;
    return NO;
}
@end
