// sources: src/Library/SFPrebuffer.m src/Library/SFPrebufferPlan.m src/Core/SFModel.m
// flags: -Isrc/Library -Isrc/Player -Isrc/Core -Isrc/Framework
// The production coordinator (SFPrebuffer) with deterministic provider/network/download state and
// no media traffic: spacing between starts, only the latest focus, gates (offline, manual
// download, sleep, provider pause) that hold work back and wake it when they lift, leave cancels.
#import "SFPrebuffer.h"
#import "SFPrebufferReader.h"
#import "SFApp.h"
#import "SFStore.h"
#import "SFNet.h"
#import "SFDownloads.h"
#import "SFMediaProxy.h"
BOOL SFDevMode = YES;
static int bad = 0;
static void expect(BOOL c, const char *what) { printf("%s %s\n", c ? "ok  " : "FAIL", what); if (!c) bad++; }

static BOOL online = YES, manual = NO;    // SFNet / SFDownloads state
static NSTimeInterval pauseUntil;         // SFBackgroundPausedUntil
static NSMutableArray *starts;            // item ids whose read was started (prepareItem:)
static NSMutableDictionary *pending;      // item id -> its unanswered resolver callback

static BOOL Until(BOOL (^ready)(void), double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!ready() && end.timeIntervalSinceNow > 0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    return ready();
}

@interface SFPrebuffer (Tests)
- (void)pump;
- (void)sleep:(NSNotification *)n;
- (void)wake:(NSNotification *)n;
@end

@interface FixtureCoordinator : SFPrebuffer
@property BOOL fixtureSleeping;
@end
@implementation FixtureCoordinator
- (BOOL)isSleeping { return self.fixtureSleeping; }
@end

// fakes of what the coordinator talks to
@interface FixtureApp : NSObject
@end
@implementation FixtureApp
+ (void)prepareItem:(SFItem *)item position:(double)p done:(void (^)(NSURL *, dispatch_block_t))done {
    [starts addObject:item.identifier];
    pending[item.identifier] = [done copy];
}
@end
@implementation SFAppRegistry
+ (Class)appForItem:(SFItem *)i { return [FixtureApp class]; }
+ (Class)appForRef:(NSString *)s { return [FixtureApp class]; }
@end
NSTimeInterval SFBackgroundPausedUntil(NSString *r) { return pauseUntil; }
NSDictionary *SFMPVSourceFor(NSURL *u) { return nil; }
@implementation SFStore
+ (instancetype)shared { static SFStore *s; if (!s) s = [SFStore new]; return s; }
- (NSArray *)history:(NSInteger)n { return @[]; }
@end
NSString *const SFNetOnlineDidChangeNotification = @"fixture-online";
@implementation SFNet
+ (BOOL)isOnline { return online; }
@end
NSString *const SFDownloadsDidChangeNotification = @"fixture-downloads";
NSString *const SFDownloadsStorageDidChangeNotification = @"fixture-storage";
@implementation SFDownloads
+ (instancetype)shared { static SFDownloads *s; if (!s) s = [SFDownloads new]; return s; }
- (NSArray *)active { return manual ? @[@1] : @[]; }
- (BOOL)storageFull { return NO; }
- (unsigned long long)freeBytes { return 1ULL << 40; }
- (unsigned long long)storageReserve { return 1ULL << 20; }
@end
@implementation SFMediaProxy
+ (instancetype)shared { static SFMediaProxy *s; if (!s) s = [SFMediaProxy new]; return s; }
+ (BOOL)canServe:(NSURL *)u { return NO; }
- (NSURL *)localURLFor:(NSURL *)u item:(NSString *)s { return u; }
- (void)releaseURL:(NSURL *)u {}
@end
@implementation SFPrebufferRead
@end
@implementation SFPrebufferReader
+ (NSDictionary *)readURL:(NSURL *)u audio:(NSURL *)a position:(double)p request:(SFPrebufferRead *)r { return @{}; }
@end

static SFItem *Item(NSString *s) {
    SFItem *i = [SFItem new];
    i.kind = SFItemVideo; i.identifier = s; i.resolverRef = s;
    return i;
}
// answers every pending resolver with "no source" (ends those reads)
static void Drain(void) {
    NSArray *callbacks = pending.allValues;
    [pending removeAllObjects];
    for (void (^f)(NSURL *, dispatch_block_t) in callbacks) f(nil, nil);
}

int main(void) { @autoreleasepool {
    setenv("SOFA_PREBUFFER_SPACING", "0.15", 1);
    setenv("SOFA_PREBUFFER_COOLDOWN", "0.4", 1);
    starts = [NSMutableArray new];
    pending = [NSMutableDictionary new];
    NSObject *owner = [NSObject new];
    SFItem *a = Item(@"fixture:a"), *b = Item(@"fixture:b");
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    FixtureCoordinator *c = [FixtureCoordinator new];
    [c offer:@[a] focused:a owner:owner];
    expect(starts.count == 1, "the first focus starts at once");
    [c offer:@[b] focused:b owner:owner];
    expect(starts.count == 1, "a focus change respects the spacing");
    expect(Until(^BOOL { return starts.count == 2; }, 1), "the replacement wakes by itself, without another offer");
    expect([starts.lastObject isEqual:b.identifier], "only the latest focused candidate starts");
    [c leave:owner]; Drain(); [starts removeAllObjects];

    c = [FixtureCoordinator new];
    online = NO;
    [c offer:@[a] focused:a owner:owner];
    expect(starts.count == 0, "offline holds candidates back");
    online = YES;
    [nc postNotificationName:SFNetOnlineDidChangeNotification object:nil];
    expect(Until(^BOOL { return starts.count == 1; }, .5), "the network's return wakes the pending candidate");
    [c leave:owner]; Drain(); [starts removeAllObjects];

    c = [FixtureCoordinator new];
    manual = YES;
    [c offer:@[a] focused:a owner:owner];
    expect(starts.count == 0, "manual downloads have priority");
    manual = NO;
    [nc postNotificationName:SFDownloadsDidChangeNotification object:nil];
    expect(Until(^BOOL { return starts.count == 1; }, .5), "the manual download's end wakes the pending candidate");
    [c leave:owner]; Drain(); [starts removeAllObjects];

    c = [FixtureCoordinator new];
    c.fixtureSleeping = YES;
    [c sleep:nil];
    [c offer:@[a] focused:a owner:owner];
    expect(starts.count == 0, "display sleep holds the candidate back");
    c.fixtureSleeping = NO;
    [c wake:nil];
    expect(starts.count == 1, "display wake rechecks the pending candidate");
    [c leave:owner]; Drain(); [starts removeAllObjects];

    c = [FixtureCoordinator new];
    pauseUntil = [NSDate date].timeIntervalSince1970 + .2;
    [c offer:@[a] focused:a owner:owner];
    expect(starts.count == 0, "a provider pause is respected");
    expect(Until(^BOOL { return starts.count == 1; }, 1), "the pause's end wakes without new offers");
    [c offer:@[b] focused:b owner:owner];
    [c leave:owner]; Drain();
    NSUInteger before = starts.count;
    Until(^BOOL { return NO; }, .4);
    expect(starts.count == before, "leaving drops deferred work");
    return bad ? 1 : 0;
} }
