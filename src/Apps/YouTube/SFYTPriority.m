#import "SFYTPriority.h"
#include <sys/resource.h>

@implementation SFYTPriority {
    void (^_apply)(BOOL);
    BOOL _want;   // @synchronized
}

- (instancetype)initWithApply:(void (^)(BOOL))apply {
    if ((self = [super init])) {
        _apply = [apply copy];
        _queue = dispatch_queue_create("sofa.yt-priority", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)want { @synchronized (self) { return _want; } }
- (void)setWant:(BOOL)want {
    @synchronized (self) { _want = want; }
    [self reapply];
}

- (void)reapply {
    __weak SFYTPriority *ws = self;
    dispatch_async(_queue, ^{
        SFYTPriority *me = ws;
        if (me) me->_apply(me.want);   // now, not when asked
    });
}
@end

NSArray *SFYTGroupPids(pid_t group, pid_t extra) {
    if (group <= 0) return @[];
    NSTask *ps = [NSTask new];
    ps.launchPath = @"/bin/ps";
    ps.arguments = @[@"-o", @"pid=", @"-g", @(group).stringValue];
    NSPipe *out = [NSPipe pipe];
    ps.standardOutput = out;
    ps.standardError = [NSFileHandle fileHandleWithNullDevice];
    @try { [ps launch]; } @catch (NSException *e) { return @[]; }
    NSData *d = [out.fileHandleForReading readDataToEndOfFile];
    [ps waitUntilExit];
    NSMutableArray *pids = [NSMutableArray new];
    if (extra > 0) [pids addObject:@(extra)];
    for (NSString *l in [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] componentsSeparatedByString:@"\n"])
        if (l.intValue > 0) [pids addObject:@(l.intValue)];
    return pids;
}

NSUInteger SFYTSetBackground(NSArray *pids, BOOL bg) {
    NSUInteger n = 0;
    for (NSNumber *p in pids) if (p.intValue > 0 && setpriority(PRIO_DARWIN_PROCESS, p.intValue, bg ? PRIO_DARWIN_BG : 0) == 0) n++;
    return n;
}

NSUInteger SFYTSetGroupBackground(pid_t group, pid_t extra, BOOL bg) {
    if (group <= 0) return 0;
    return SFYTSetBackground(SFYTGroupPids(group, extra), bg);
}
