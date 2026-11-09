// sources: src/Core/SFLocalHTTP.m src/Core/SFWebSocket.m src/Core/SFHTTPBudget.m src/Library/SFMediaStore.m src/Library/SFExtentSet.m src/Apps/YouTube/SFYTEngine+Media.m src/Apps/YouTube/SFYTEngine+Store.m
// flags: -Isrc/Library -Isrc/Player -Isrc/Browse -Isrc/Shell -Isrc/Apps/YouTube -I/opt/local/include -lsqlite3
// The player's requests on a YouTube track, newest wins (SFYTEngine+Media/Store): a request is
// superseded once a newer one on the same track began (per track, per session; a session not in the
// table is never superseded); a superseded read still gets what is on disk, but asks the engine for
// nothing (409) - mpv's header-parse connection left open after a resume served from the store
// started a second SABR run (2026-11-09).
#import "SFYTEngine+Private.h"
#import "SFDownloads.h"
#import "SFMediaStore.h"
BOOL SFDevMode = YES;
static int bad = 0;
static void expect(BOOL c, const char *what) { printf("%s %s\n", c ? "ok  " : "FAIL", what); fflush(stdout); if (!c) bad++; }

static SFMediaStore *gStore;
static NSData *gVideo;            // the source's bytes of the video track
static NSMutableArray *gReads;    // offsets the fake engine was asked for

NSError *SFError(NSString *m) { return [NSError errorWithDomain:@"fixture" code:1 userInfo:@{NSLocalizedDescriptionKey: m}]; }

@implementation SFDownloads
+ (instancetype)shared {
    static SFDownloads *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [SFDownloads new]; });
    return d;
}
- (SFMediaStore *)mediaStore { return gStore; }
@end

@implementation SFYTEngine {
    dispatch_queue_t _q;
}
+ (instancetype)shared {
    static SFYTEngine *e;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ e = [SFYTEngine new]; });
    return e;
}
- (dispatch_queue_t)queue { return _q ?: (_q = dispatch_queue_create("ytsupersede", DISPATCH_QUEUE_SERIAL)); }
- (void)request:(NSString *)method args:(NSArray *)args timeout:(NSTimeInterval)timeout done:(void (^)(id, NSError *))done {
    dispatch_async(self.queue, ^{
        NSUInteger at = [args[2] unsignedIntegerValue], n = MIN([args[3] unsignedIntegerValue], gVideo.length - at);
        [gReads addObject:@(at)];
        done(@{@"data": [gVideo subdataWithRange:NSMakeRange(at, n)], @"total": @(gVideo.length), @"id": @"fixture:video", @"mimeType": @"video/webm"}, nil);
    });
}
@end

@interface SFYTEngine (ReadSuperseded)
- (void)read:(NSString *)sid track:(NSString *)key at:(long long)offset max:(NSUInteger)max superseded:(BOOL (^)(void))superseded
        done:(void (^)(NSData *bytes, long long total, NSString *mime, NSError *e))done;
@end

// one read on the engine queue, waited for
static NSDictionary *Read(SFYTEngine *engine, long long at, BOOL (^superseded)(void)) {
    __block NSDictionary *r = nil;
    dispatch_semaphore_t got = dispatch_semaphore_create(0);
    dispatch_async(engine.queue, ^{
        [engine read:@"sid1" track:@"video" at:at max:4096 superseded:superseded done:^(NSData *bytes, long long total, NSString *mime, NSError *e) {
            r = @{@"bytes": @(bytes.length), @"code": @(e.code)};
            dispatch_semaphore_signal(got);
        }];
    });
    dispatch_semaphore_wait(got, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    return r;
}

int main(void) { @autoreleasepool {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ytsupersede-%d", getpid()]];
    gStore = [[SFMediaStore alloc] initWithDirectory:dir];
    NSMutableData *v = [NSMutableData dataWithLength:1 << 20];
    arc4random_buf(v.mutableBytes, v.length);
    gVideo = v;
    gReads = [NSMutableArray new];
    SFYTEngine *engine = [SFYTEngine shared];
    // the stored start of the track (a resume: its init region and more came from disk)
    [gStore write:[gVideo subdataWithRange:NSMakeRange(0, 65536)] key:@"fixture:video" item:@"yt:fixture" kind:@"video" total:(long long)gVideo.length at:0];
    [gStore sync];
    [engine noteSession:@"sid1" video:@"fixture" stored:NO tracks:@{@"video": @{@"id": @"fixture:video", @"total": @(gVideo.length), @"mimeType": @"video/webm"}}];

    NSUInteger a = [engine beginRequestOn:@"video" session:@"sid1"];
    expect(a > 0 && ![engine request:a supersededOn:@"video" session:@"sid1"], "a request alone is not superseded");
    NSUInteger audio = [engine beginRequestOn:@"audio" session:@"sid1"];
    expect(![engine request:a supersededOn:@"video" session:@"sid1"], "a request on another track supersedes nothing");
    NSUInteger b = [engine beginRequestOn:@"video" session:@"sid1"];
    expect([engine request:a supersededOn:@"video" session:@"sid1"] && ![engine request:b supersededOn:@"video" session:@"sid1"]
           && ![engine request:audio supersededOn:@"audio" session:@"sid1"], "the newer request on the track supersedes the older one");
    expect([engine beginRequestOn:@"video" session:@"unknown"] == 0 && ![engine request:0 supersededOn:@"video" session:@"unknown"],
           "a session not in the table: no numbering, never superseded");

    BOOL (^yes)(void) = ^BOOL { return YES; };
    NSDictionary *disk = Read(engine, 0, yes);
    expect([disk[@"bytes"] integerValue] > 0 && gReads.count == 0, "superseded: what is on disk is still served, no engine read");
    NSDictionary *left = Read(engine, 65536, yes);
    expect([left[@"code"] integerValue] == 409 && gReads.count == 0, "superseded past the stored start: 409, no engine read (no SABR run)");
    NSDictionary *live = Read(engine, 65536, ^BOOL { return NO; });
    expect([live[@"bytes"] integerValue] == 4096 && gReads.count == 1, "the current request past the stored start: read from the engine");
    [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    return bad ? 1 : 0;
} }
