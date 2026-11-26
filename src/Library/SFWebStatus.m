#import "SFWebStatus.h"
#import "SFWebTV.h"
#import "SFWebItems.h"
#import "SFDownloads.h"
#import "SFPlayerScreen.h"

static const NSTimeInterval kWait = 25;          // a quiet long poll answers after this (well inside the PWA's 60 s)
static const NSTimeInterval kProgressWait = 3;   // while a download runs: its progress
static const NSTimeInterval kCoalesce = 0.25;    // a burst of changes (a player opening) is one answer
static const NSUInteger kMaxWaiting = 64;        // waiting browsers; the oldest is answered early beyond that

@interface SFWebStatusWaiter : NSObject
@property (nonatomic, strong) SFHTTPExchange *exchange;
@property (nonatomic) BOOL answered;
@end
@implementation SFWebStatusWaiter
@end

@implementation SFWebStatus {
    NSString *_launch;
    NSUInteger _n;
    NSMutableArray *_waiting;   // SFWebStatusWaiter, oldest first
    BOOL _flushPending;
}

+ (instancetype)shared {
    static SFWebStatus *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SFWebStatus new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _launch = [[[NSUUID UUID] UUIDString] substringToIndex:8].lowercaseString;
        _waiting = [NSMutableArray new];
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(changed) name:SFPlayerStateNotification object:nil];
        [nc addObserver:self selector:@selector(changed) name:SFDownloadsDidChangeNotification object:nil];
    }
    return self;
}

- (NSString *)generation { return [NSString stringWithFormat:@"%@-%lu", _launch, (unsigned long)_n]; }

- (NSDictionary *)current {
    NSArray *active = [[SFDownloads shared] active] ?: @[];
    return @{@"gen": [self generation], @"tv": [[SFWebTV shared] state] ?: [NSNull null], @"downloads": [SFWebItems items:active]};
}

- (BOOL)downloadRunning {
    for (SFItem *i in [[SFDownloads shared] active]) if ([[SFDownloads shared] stateFor:i.identifier progress:NULL] == SFDLRunning) return YES;
    return NO;
}

- (void)answer:(SFHTTPExchange *)x since:(NSString *)since {
    if (![since isEqualToString:[self generation]]) { [self reply:x]; return; }
    SFWebStatusWaiter *w = [SFWebStatusWaiter new];
    w.exchange = x;
    [_waiting addObject:w];
    while (_waiting.count > kMaxWaiting) { SFWebStatusWaiter *old = _waiting[0]; [_waiting removeObjectAtIndex:0]; [self settle:old]; }
    NSTimeInterval wait = [self downloadRunning] ? kProgressWait : kWait;
    __weak SFWebStatus *ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SFWebStatus *me = ws;
        if (!me || w.answered) return;
        [me->_waiting removeObjectIdenticalTo:w];
        [me settle:w];
    });
}

- (void)settle:(SFWebStatusWaiter *)w {
    if (w.answered) return;
    w.answered = YES;
    [self reply:w.exchange];
}

- (void)reply:(SFHTTPExchange *)x {
    NSDictionary *now = [self current];
    dispatch_async(x.queue, ^{ [x respondJSON:200 object:now]; });
}

- (void)changed {
    _n++;
    if (_flushPending) return;
    _flushPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kCoalesce * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self->_flushPending = NO;
        NSArray *all = [self->_waiting copy];
        [self->_waiting removeAllObjects];
        for (SFWebStatusWaiter *w in all) [self settle:w];
    });
}
@end
