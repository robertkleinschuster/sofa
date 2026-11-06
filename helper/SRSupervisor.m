#import "SRSupervisor.h"

@implementation SRSupervisor {
    NSDate *_goneSince;
    NSMutableArray *_relaunches;   // NSDate of each relaunch in the window
}

- (instancetype)init {
    if ((self = [super init])) { _grace = 10; _maxRelaunches = 3; _window = 600; _relaunches = [NSMutableArray new]; }
    return self;
}

- (BOOL)shouldRelaunchAt:(NSDate *)now running:(BOOL)running markerLeft:(BOOL)markerLeft {
    if (running || !markerLeft) {   // running, or ended as planned: nothing to do
        _goneSince = nil;
        if (running) _gaveUp = NO;
        return NO;
    }
    if (!_goneSince) _goneSince = now;
    if ([now timeIntervalSinceDate:_goneSince] < _grace || _gaveUp) return NO;
    NSDate *cut = [now dateByAddingTimeInterval:-_window];
    [_relaunches filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDate *d, NSDictionary *b) { return [d compare:cut] == NSOrderedDescending; }]];
    if (_relaunches.count >= _maxRelaunches) { _gaveUp = YES; return NO; }
    [_relaunches addObject:now];
    _goneSince = nil;   // the next grace period starts if this launch does not come up
    return YES;
}
@end
