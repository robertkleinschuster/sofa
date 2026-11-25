// SFYTEngine (Browser) - sessions for Sofa im Browser (docs/pwa.md).
#import "SFYTEngine+Private.h"
#import "SFRest.h"

@implementation SFYTEngine (Browser)

- (void)openForBrowser:(NSString *)vid done:(void (^)(NSDictionary *, NSError *))done {
    // as the TV's open (prefetch off: the reader's requests drive SABR; critical heat: 720p), with the
    // codecs the browser plays, as a requirement (onlyCodecs: no other format instead; res/sofa-yt lib/engine.ts)
    [self open:vid request:@{@"v": vid ?: @"", @"bg": @NO, @"maxHeight": @([SFRest thermalLevel] >= 3 ? 720 : 1080), @"lang": @"de",
                             @"prefetch": @NO, @"vcodec": @"avc1", @"acodec": @"mp4a", @"onlyCodecs": @YES} done:done];
}
@end
