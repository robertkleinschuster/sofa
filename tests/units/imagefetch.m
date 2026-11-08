// sources: src/Framework/SFLayers.m src/Core/SFHostFetch.m
// SFImageCache: a picture fetched through a source's own client (SFHostFetch) that never answers
// still completes - without a picture, after the fetch limit - instead of holding one of the six
// fetch slots for the session (review 2026-11-08: the wait had no limit).
#import "SFCore.h"
#import "SFLayers.h"
#import "SFHostFetch.h"
#include <stdlib.h>

BOOL SFDevMode = YES;   // SFDevEnv: the shortened limit below
// SFNet.m's (it pulls in the store): the cache's native session is built but never used here
id<NSURLSessionDelegate> SFTrustAllSessionDelegate(void) { return nil; }
static int bad = 0;
static void expect(BOOL c, const char *what) { printf("%s %s\n", c ? "ok  " : "FAIL", what); if (!c) bad++; }

int main(void) { @autoreleasepool {
    char dir[] = "/tmp/sofa-imagefetch.XXXXXX";
    if (!mkdtemp(dir)) return 1;
    setenv("SOFA_DATA_DIR", dir, 1);   // the cache lives in a throwaway dev instance, never the real one
    setenv("SOFA_IMAGE_FETCH_LIMIT", "0.5", 1);
    SFSetDevInstance(@"unit");

    __block int asked = 0;
    SFRegisterHostFetcher(@[@"img.never.test"], ^(NSURL *u, SFHostFetchDone d) { asked++; });   // never answers
    __block BOOL done = NO; __block BOOL gotImage = YES;
    NSDate *t0 = [NSDate date];
    [[SFImageCache shared] imageForSource:@"https://img.never.test/a.jpg" maxPixel:256 blurred:NO completion:^(CGImageRef img) {
        done = YES; gotImage = img != NULL;
    }];
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!done && [limit timeIntervalSinceNow] > 0) [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    NSTimeInterval took = -[t0 timeIntervalSinceNow];
    expect(asked == 1, "the source's own client was asked");
    expect(done, "the caller hears back although the client never answers");
    expect(done && !gotImage, "without a picture");
    expect(done && took >= 0.4 && took < 3, "after the fetch limit");
    [[NSFileManager defaultManager] removeItemAtPath:@(dir) error:nil];
    return bad ? 1 : 0;
} }
