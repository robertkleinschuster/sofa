// SFYTEngine (Browser) - sessions for clients of the web API (Sofa im Browser, the native apps; docs/pwa.md).
#import "SFYTEngine+Private.h"
#import "SFYTBrowserFormats.h"
#import "SFRest.h"

@implementation SFYTEngine (Browser)

- (void)openForBrowser:(NSString *)vid formats:(NSArray *)formats done:(void (^)(NSDictionary *, NSError *))done {
    // as the TV's open (prefetch off: the reader's requests drive SABR; critical heat: 720p), with the
    // codecs the client plays as a requirement, in its order (res/sofa-yt lib/engine.ts: vcodecs/acodecs)
    NSDictionary *codecs = SFYTBrowserCodecs(formats);
    [self open:vid request:@{@"v": vid ?: @"", @"bg": @NO, @"maxHeight": @([SFRest thermalLevel] >= 3 ? 720 : 1080), @"lang": @"de",
                             @"prefetch": @NO, @"vcodecs": codecs[@"vcodecs"], @"acodecs": codecs[@"acodecs"]} done:done];
}
@end
