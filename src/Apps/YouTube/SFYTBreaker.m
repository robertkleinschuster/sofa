#import "SFYTBreaker.h"

@implementation SFYTBreaker {
    NSTimeInterval _noted;                 // from the last answer (sidecar) or the dev command
    NSTimeInterval _fromFile, _readAt;     // the shared file, re-read at most every 2 s
}

+ (instancetype)shared {
    static SFYTBreaker *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [SFYTBreaker new]; });
    return s;
}

+ (NSString *)filePath {
    return [SFSharedCacheDir() stringByAppendingPathComponent:@"youtube-block.json"];   // one IP: every instance
}

- (NSTimeInterval)blockedUntil {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - _readAt > 2) {
        _readAt = now;
        NSData *d = [NSData dataWithContentsOfFile:[SFYTBreaker filePath]];
        NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        _fromFile = [j isKindOfClass:[NSDictionary class]] ? [j[@"until"] doubleValue] : 0;
    }
    NSTimeInterval until = MAX(_fromFile, _noted);
    return until > now ? until : 0;
}

- (void)noteBlockedUntil:(NSTimeInterval)until {
    if (until > _noted) _noted = until;
    _readAt = 0;   // re-read the shared file on the next check
}

- (void)simulateBlockForTesting:(NSTimeInterval)secs {
    _noted = [NSDate date].timeIntervalSince1970 + MAX(0, secs);
    SFLog(@"dev: YouTube pause simulated for %.0f s", secs);
}
@end
