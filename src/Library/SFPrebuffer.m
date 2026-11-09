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

@implementation SFPrebuffer {
    __weak id _owner;
    NSHashTable *_players;
    NSArray *_candidates;
    NSMutableDictionary *_attempted;
    NSMutableArray *_starts;
    SFPrebufferRead *_active;
    NSString *_activeID, *_focusID;
    dispatch_queue_t _worker;
    BOOL _asleep;
    NSTimeInterval _wakeAt;
    NSUInteger _wakeGeneration;
}
+ (instancetype)shared { static SFPrebuffer *s; static dispatch_once_t once; dispatch_once(&once,^{s=[SFPrebuffer new];}); return s; }
- (instancetype)init {
    if ((self=[super init])) {
        _players=[NSHashTable weakObjectsHashTable]; _attempted=[NSMutableDictionary new]; _starts=[NSMutableArray new];
        _worker=dispatch_queue_create("sofa.prebuffer",DISPATCH_QUEUE_SERIAL);
        NSNotificationCenter *nc=[[NSWorkspace sharedWorkspace] notificationCenter];
        [nc addObserver:self selector:@selector(sleep:) name:NSWorkspaceScreensDidSleepNotification object:nil];
        [nc addObserver:self selector:@selector(wake:) name:NSWorkspaceScreensDidWakeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(stateChanged:) name:SFNetOnlineDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(stateChanged:) name:SFDownloadsDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(stateChanged:) name:SFDownloadsStorageDidChangeNotification object:nil];
    } return self;
}
- (void)cancel { _active.cancelled=YES; _active=nil; _activeID=nil; }
- (void)sleep:(NSNotification *)n { _asleep=YES; [self cancel]; }
- (void)wake:(NSNotification *)n { _asleep=NO; [self pump]; }
- (void)stateChanged:(NSNotification *)n { SFMain(^{
    // A manual download or lost network takes priority even after speculative work has started.
    if (![SFNet isOnline] || [SFDownloads shared].active.count || [SFDownloads shared].storageFull) [self cancel];
    [self pump];
}); }
- (BOOL)isSleeping { return _asleep || (CGDisplayIsAsleep(CGMainDisplayID()) && !SFDevEnv(@"SOFA_PREBUFFER_TEST")); }
- (void)wakeAt:(NSTimeInterval)when {
    NSTimeInterval now=[NSDate date].timeIntervalSince1970;
    if (_wakeAt>now && _wakeAt<=when) return;
    _wakeAt=when;NSUInteger generation=++_wakeGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(MAX(.01,when-now)*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        if (generation!=self->_wakeGeneration) return;
        self->_wakeAt=0;[self pump];
    });
}
- (void)suspendForPlayer:(id)player { [_players addObject:player]; [self cancel]; }
- (void)leave:(id)owner {
    [_players removeObject:owner];
    if (_owner==owner) { _owner=nil; _candidates=nil; _wakeAt=0;_wakeGeneration++;[self cancel]; }
    else if (!_players.count && _owner) [self pump];
}
- (void)offer:(NSArray *)suggestions focused:(SFItem *)focused owner:(id)owner {
    _owner=owner;
    _candidates=[SFPrebufferPlan candidates:suggestions focused:focused history:[[SFStore shared] history:100] now:[NSDate date].timeIntervalSince1970];
    if (_active && ![_focusID isEqualToString:focused.identifier]) [self cancel];
    _focusID=focused.identifier;
    [self pump];
}
- (void)pump {
    BOOL sleeping=[self isSleeping];
    if (SFDevEnv(@"SOFA_PREBUFFER_TEST")) SFLog(@"prebuffer-test: active=%d owner=%d players=%lu sleeping=%d online=%d candidates=%lu",_active!=nil,_owner!=nil,(unsigned long)_players.count,sleeping,[SFNet isOnline],(unsigned long)_candidates.count);
    if (_active || !_owner || _players.count || sleeping || ![SFNet isOnline]) return;
    NSTimeInterval now=[NSDate date].timeIntervalSince1970;
    while (_starts.count && now-[_starts[0] doubleValue]>3600) [_starts removeObjectAtIndex:0];
    for (NSString *key in [_attempted.allKeys copy]) if (now-[_attempted[key] doubleValue]>3600) [_attempted removeObjectForKey:key];
    if (_starts.count>=12) { [self wakeAt:[_starts[0] doubleValue]+3600.05]; return; }
    NSTimeInterval spacing=SFDevSeconds(@"SOFA_PREBUFFER_SPACING",20);
    if (_starts.count && now-[_starts.lastObject doubleValue]<spacing) { [self wakeAt:[_starts.lastObject doubleValue]+spacing+.01]; return; }
    if ([SFDownloads shared].active.count) return; // manual full fills own the source before predictions
    if ([SFDownloads shared].storageFull || [SFDownloads shared].freeBytes<[SFDownloads shared].storageReserve) return;
    NSDictionary *choice=nil;NSTimeInterval earliest=0;
    NSTimeInterval cooldown=SFDevSeconds(@"SOFA_PREBUFFER_COOLDOWN",600);
    for (NSDictionary *c in _candidates) {
        SFItem *i=c[@"item"];
        NSTimeInterval eligible=MAX([_attempted[i.identifier] doubleValue]+cooldown,SFBackgroundPausedUntil(i.resolverRef ?: i.identifier));
        if(eligible>now) {earliest=earliest ? MIN(earliest,eligible) : eligible;continue;}
        choice=c;break;
    }
    if (!choice) { if(earliest) [self wakeAt:earliest+.01]; return; }
    SFItem *item=choice[@"item"]; double position=[choice[@"position"] doubleValue];
    _attempted[item.identifier]=@(now); [_starts addObject:@(now)];
    SFPrebufferRead *request=[SFPrebufferRead new]; _active=request; _activeID=item.identifier;
    // A resolver that never answers cannot hold the coordinator permanently.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,45*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if (self->_active==request) { [self cancel]; [self pump]; }
    });
    Class<SFApp> app=[SFAppRegistry appForItem:item];
    void (^resolved)(NSURL *,dispatch_block_t)=^(NSURL *url,dispatch_block_t cleanup) {
        SFMain(^{
            if (request.cancelled || self->_active!=request || !url) {
                if (!url && !request.cancelled) SFLog(@"prebuffer: %@ at %.1fs: source unavailable",item.identifier,position);
                if (cleanup) cleanup();
                if (self->_active==request) { [self cancel]; [self scheduleNext]; }
                return;
            }
            NSDictionary *source=SFMPVSourceFor(url);
            NSURL *audio=[source[@"audio"] isKindOfClass:[NSString class]] ? [NSURL URLWithString:source[@"audio"]] : nil;
            NSURL *local=[SFMediaProxy canServe:url] ? [[SFMediaProxy shared] localURLFor:url item:item.identifier] : url;
            // No direct CDN/file reads: only our existing persistent-store proxies are useful.
            if (![local.host isEqualToString:@"127.0.0.1"]) { if(cleanup)cleanup();[self cancel];[self scheduleNext];return; }
            dispatch_async(self->_worker,^{
                NSDictionary *result=[SFPrebufferReader readURL:local audio:audio position:position request:request];
                [[SFMediaProxy shared] releaseURL:local];
                SFMain(^{
                    if (cleanup) cleanup();
                    SFLog(@"prebuffer: %@ at %.1fs: %@",item.identifier,position,result);
                    if (self->_active==request) { [self cancel]; [self scheduleNext]; }
                });
            });
        });
    };
    if ([app respondsToSelector:@selector(prepareItem:position:done:)]) [app prepareItem:item position:position done:resolved];
    else [item resolveURL:^(NSURL *url,NSError *error){ resolved(url,nil); }];
}
- (void)scheduleNext { if(_owner) [self wakeAt:[NSDate date].timeIntervalSince1970+SFDevSeconds(@"SOFA_PREBUFFER_SPACING",20)]; }
@end
