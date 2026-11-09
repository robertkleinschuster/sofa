#import "SFPrebuffer.h"
#import "SFPrebufferPlan.h"
#import "SFPrebufferReader.h"
#import "SFApp.h"
#import "SFStore.h"
#import "SFNet.h"
#import "SFDownloads.h"
#import "SFMediaStore.h"
#import "SFMediaProxy.h"
#import "SFEngine.h"

static const NSUInteger kStartsPerHour = 12;            // reads started within the last hour
static const NSTimeInterval kSpacing = 20;              // between two reads (SOFA_PREBUFFER_SPACING)
static const NSTimeInterval kCooldown = 600;            // one item again after (SOFA_PREBUFFER_COOLDOWN)
static const NSTimeInterval kResolveDeadline = 45;      // a resolver that never answers releases the slot

@implementation SFPrebuffer {
    __weak id _owner;               // the screen whose suggestions are offered
    NSHashTable *_players;          // open players: no speculative reads while any is there
    NSArray *_candidates;           // SFPrebufferPlan's {item, position}
    NSMutableDictionary *_attempted;   // item id -> last start (epoch)
    NSMutableArray *_starts;        // start times within the last hour
    SFPrebufferRead *_active;
    NSString *_activeID, *_focusID;
    dispatch_queue_t _worker;
    BOOL _asleep;
    NSTimeInterval _wakeAt;
    NSUInteger _wakeGeneration;
}

+ (instancetype)shared {
    static SFPrebuffer *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SFPrebuffer new]; });
    return s;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _players = [NSHashTable weakObjectsHashTable];
    _attempted = [NSMutableDictionary new];
    _starts = [NSMutableArray new];
    _worker = dispatch_queue_create("sofa.prebuffer", DISPATCH_QUEUE_SERIAL);
    NSNotificationCenter *ws = [[NSWorkspace sharedWorkspace] notificationCenter], *nc = [NSNotificationCenter defaultCenter];
    [ws addObserver:self selector:@selector(sleep:) name:NSWorkspaceScreensDidSleepNotification object:nil];
    [ws addObserver:self selector:@selector(wake:) name:NSWorkspaceScreensDidWakeNotification object:nil];
    [nc addObserver:self selector:@selector(stateChanged:) name:SFNetOnlineDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(stateChanged:) name:SFDownloadsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(stateChanged:) name:SFDownloadsStorageDidChangeNotification object:nil];
    return self;
}

- (void)cancel { _active.cancelled = YES; _active = nil; _activeID = nil; }
- (void)sleep:(NSNotification *)n { _asleep = YES; [self cancel]; }
- (void)wake:(NSNotification *)n { _asleep = NO; [self pump]; }

- (void)stateChanged:(NSNotification *)n {
    SFMain(^{
        // a manual download or a lost network takes priority even over a read already running
        SFDownloads *d = [SFDownloads shared];
        if (![SFNet isOnline] || d.active.count || d.storageFull) [self cancel];
        [self pump];
    });
}

- (BOOL)isSleeping { return _asleep || (CGDisplayIsAsleep(CGMainDisplayID()) && !SFDevEnv(@"SOFA_PREBUFFER_TEST")); }

// one pending wake-up: the earliest wins, a later request keeps it
- (void)wakeAt:(NSTimeInterval)when {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (_wakeAt > now && _wakeAt <= when) return;
    _wakeAt = when;
    NSUInteger generation = ++_wakeGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(.01, when - now) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self->_wakeGeneration) return;
        self->_wakeAt = 0;
        [self pump];
    });
}

- (void)suspendForPlayer:(id)player { [_players addObject:player]; [self cancel]; }

- (void)leave:(id)owner {
    [_players removeObject:owner];
    if (_owner == owner) {
        _owner = nil; _candidates = nil; _wakeAt = 0; _wakeGeneration++;
        [self cancel];
    } else if (!_players.count && _owner) [self pump];
}

- (void)offer:(NSArray *)suggestions focused:(SFItem *)focused owner:(id)owner {
    _owner = owner;
    _candidates = [SFPrebufferPlan candidates:suggestions focused:focused history:[[SFStore shared] history:100]
                                          now:[NSDate date].timeIntervalSince1970];
    if (_active && ![_focusID isEqualToString:focused.identifier]) [self cancel];
    _focusID = focused.identifier;
    [self pump];
}

// the first candidate past its cooldown and any background pause; nil and *earliest when none is yet
- (NSDictionary *)nextCandidateAt:(NSTimeInterval)now earliest:(NSTimeInterval *)earliest {
    NSTimeInterval cooldown = SFDevSeconds(@"SOFA_PREBUFFER_COOLDOWN", kCooldown);
    *earliest = 0;
    for (NSDictionary *c in _candidates) {
        SFItem *i = c[@"item"];
        NSTimeInterval eligible = MAX([_attempted[i.identifier] doubleValue] + cooldown, SFBackgroundPausedUntil(i.resolverRef ?: i.identifier));
        if (eligible <= now) return c;
        *earliest = *earliest ? MIN(*earliest, eligible) : eligible;
    }
    return nil;
}

- (void)pump {
    BOOL sleeping = [self isSleeping];
    if (SFDevEnv(@"SOFA_PREBUFFER_TEST"))
        SFLog(@"prebuffer-test: active=%d owner=%d players=%lu sleeping=%d online=%d candidates=%lu", _active != nil, _owner != nil,
              (unsigned long)_players.count, sleeping, [SFNet isOnline], (unsigned long)_candidates.count);
    if (_active || !_owner || _players.count || sleeping || ![SFNet isOnline]) return;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    while (_starts.count && now - [_starts[0] doubleValue] > 3600) [_starts removeObjectAtIndex:0];
    for (NSString *key in [_attempted.allKeys copy])
        if (now - [_attempted[key] doubleValue] > 3600) [_attempted removeObjectForKey:key];
    if (_starts.count >= kStartsPerHour) { [self wakeAt:[_starts[0] doubleValue] + 3600.05]; return; }
    NSTimeInterval spacing = SFDevSeconds(@"SOFA_PREBUFFER_SPACING", kSpacing);
    if (_starts.count && now - [_starts.lastObject doubleValue] < spacing) { [self wakeAt:[_starts.lastObject doubleValue] + spacing + .01]; return; }
    SFDownloads *d = [SFDownloads shared];
    if (d.active.count) return;   // manual full fills own the source before predictions
    if (d.storageFull || d.freeBytes < d.storageReserve) return;
    NSTimeInterval earliest;
    NSDictionary *choice = [self nextCandidateAt:now earliest:&earliest];
    if (!choice) { if (earliest) [self wakeAt:earliest + .01]; return; }
    [self startRead:choice[@"item"] position:[choice[@"position"] doubleValue] now:now];
}

- (void)startRead:(SFItem *)item position:(double)position now:(NSTimeInterval)now {
    _attempted[item.identifier] = @(now);
    [_starts addObject:@(now)];
    SFPrebufferRead *request = [SFPrebufferRead new];
    _active = request; _activeID = item.identifier;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kResolveDeadline * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_active == request) { [self cancel]; [self pump]; }
    });
    void (^resolved)(NSURL *, dispatch_block_t) = ^(NSURL *url, dispatch_block_t cleanup) {
        SFMain(^{
            if (request.cancelled || self->_active != request || !url) {
                if (!url && !request.cancelled) SFLog(@"prebuffer: %@ at %.1fs: source unavailable", item.identifier, position);
                if (cleanup) cleanup();
                [self finish:request];
                return;
            }
            NSDictionary *source = SFMPVSourceFor(url);
            NSURL *audio = [source[@"audio"] isKindOfClass:[NSString class]] ? [NSURL URLWithString:source[@"audio"]] : nil;
            NSURL *local = [SFMediaProxy canServe:url] ? [[SFMediaProxy shared] localURLFor:url item:item.identifier] : url;
            // no direct CDN/file reads: only the store-backed proxies put what is read into the common buffer
            if (![local.host isEqualToString:@"127.0.0.1"]) { if (cleanup) cleanup(); [self finish:request]; return; }
            dispatch_async(self->_worker, ^{
                NSDictionary *result = [SFPrebufferReader readURL:local audio:audio position:position request:request];
                [[SFMediaProxy shared] releaseURL:local];
                SFMain(^{
                    if (cleanup) cleanup();
                    SFLog(@"prebuffer: %@ at %.1fs: %@", item.identifier, position, result);
                    [self finish:request];
                });
            });
        });
    };
    Class<SFApp> app = [SFAppRegistry appForItem:item];
    if ([app respondsToSelector:@selector(prepareItem:position:done:)]) [app prepareItem:item position:position done:resolved];
    else [item resolveURL:^(NSURL *url, NSError *error) { resolved(url, nil); }];
}

// a read is over: the next one after the spacing (unless another read has replaced it)
- (void)finish:(SFPrebufferRead *)request {
    if (_active != request) return;
    [self cancel];
    if (_owner) [self wakeAt:[NSDate date].timeIntervalSince1970 + SFDevSeconds(@"SOFA_PREBUFFER_SPACING", kSpacing)];
}

@end
