// sources: src/Core/SFLocalHTTP.m src/Core/SFWebSocket.m src/Core/SFHTTPBudget.m src/Library/SFMediaStore.m src/Library/SFExtentSet.m src/Library/SFPrebufferReader.m src/Apps/YouTube/SFYTEngine+Media.m src/Apps/YouTube/SFYTEngine+Store.m src/Apps/YouTube/SFYTEngine+Fill.m
// flags: -Isrc/Library -Isrc/Player -Isrc/Browse -Isrc/Shell -Isrc/Apps/YouTube -I/opt/local/include -L/opt/local/lib -lmpv -lsqlite3
// The YouTube media path end to end with libmpv and the real store/fill code; only the browser RPC
// is a fake (local files, the first read of each track delayed 6 s like a real SABR start):
// a predictive read at 70 s leaves a partial buffer in the persistent store, the manual fill
// fetches exactly the missing bytes into that same buffer, the complete buffer opens as a stored
// session that demuxes offline, and it persists across a store reopen.
#import "SFYTEngine+Private.h"
#import "SFDownloads.h"
#import "SFMediaStore.h"
#import "SFPrebufferReader.h"
#import "SFJSON.h"
#include <math.h>
BOOL SFDevMode = YES;
static int bad = 0;
static void expect(BOOL c, const char *what) { printf("%s %s\n", c ? "ok  " : "FAIL", what); fflush(stdout); if (!c) bad++; }

static SFMediaStore *gStore;
static NSDictionary *gFiles;          // track key -> the source's bytes (nil = the source is offline)
static NSUInteger gFetched;           // bytes the fake RPC delivered
static NSDictionary *gAnswer;         // the open answer of the online session
static NSMutableSet *gFirstReads;     // tracks whose first read was delayed

NSError *SFError(NSString *m) { return [NSError errorWithDomain:@"fixture" code:1 userInfo:@{NSLocalizedDescriptionKey: m}]; }

// the download/store owner, isolated: no application database, settings or browser
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
    dispatch_queue_t _fixtureQueue;
    SFLocalHTTP *_fixtureServer;
}
+ (instancetype)shared {
    static SFYTEngine *e;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ e = [SFYTEngine new]; });
    return e;
}
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _fixtureQueue = dispatch_queue_create("yt-prebuffer-fixture", DISPATCH_QUEUE_SERIAL);
    __weak SFYTEngine *w = self;
    _fixtureServer = [[SFLocalHTTP alloc] initWithName:@"yt-prebuffer-fixture" queue:_fixtureQueue maxBody:0 handler:^(SFHTTPExchange *x) { [w serveSession:x]; }];
    [_fixtureServer startPreferringPort:0];
    return self;
}
- (dispatch_queue_t)queue { return _fixtureQueue; }
- (NSString *)mediaBase { return [NSString stringWithFormat:@"http://127.0.0.1:%u", _fixtureServer.port]; }
- (void)request:(NSString *)method args:(NSArray *)args timeout:(NSTimeInterval)timeout done:(void (^)(id, NSError *))done {
    dispatch_async(_fixtureQueue, ^{
        if (![method isEqual:@"read"]) { done(nil, SFError(@"unexpected RPC")); return; }
        NSString *key = args[1];
        NSData *data = gFiles[key];
        NSUInteger at = [args[2] unsignedIntegerValue], max = [args[3] unsignedIntegerValue];
        if (!data || at >= data.length) { done(nil, SFError(@"source offline or invalid read")); return; }
        NSUInteger n = MIN(max, data.length - at);
        dispatch_block_t deliver = ^{
            gFetched += n;
            done(@{@"data": [data subdataWithRange:NSMakeRange(at, n)], @"total": @(data.length), @"id": [@"fixture:" stringByAppendingString:key],
                   @"mimeType": [key isEqual:@"video"] ? @"video/mp4" : @"audio/mp4"}, nil);
        };
        // a real SABR start can take token setup plus ~5 s to its first segment: a five-second
        // HTTP timeout would abort before either track has useful bytes
        if (![gFirstReads containsObject:key]) {
            [gFirstReads addObject:key];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), self->_fixtureQueue, deliver);
        } else deliver();
    });
}
- (void)open:(NSString *)vid background:(BOOL)bg stored:(BOOL)stored done:(void (^)(NSDictionary *, NSError *))done {
    NSDictionary *r = stored ? [self storedAnswer:vid] : nil;
    done(r ?: gAnswer, nil);
}
- (void)closeSession:(NSString *)sid {}   // the fake RPC holds no browser resources
@end

static BOOL Until(BOOL (^ready)(void), double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!ready() && end.timeIntervalSinceNow > 0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    return ready();
}

// a 180 s track of one kind ("video" or "audio") made by ffmpeg
static NSData *Track(NSString *dir, NSString *kind) {
    NSString *path = [dir stringByAppendingPathComponent:[kind stringByAppendingString:@".mp4"]];
    NSArray *media = [kind isEqual:@"video"]
        ? @[@"-f", @"lavfi", @"-i", @"testsrc=size=320x180:rate=10", @"-t", @"180", @"-c:v", @"libx264", @"-preset", @"ultrafast", @"-an"]
        : @[@"-f", @"lavfi", @"-i", @"sine=frequency=440", @"-t", @"180", @"-vn", @"-c:a", @"aac"];
    NSMutableArray *a = [@[@"-hide_banner", @"-loglevel", @"error", @"-y"] mutableCopy];
    [a addObjectsFromArray:media];
    [a addObjectsFromArray:@[@"-movflags", @"+faststart", path]];
    NSTask *t = [NSTask launchedTaskWithLaunchPath:@"/opt/local/bin/ffmpeg" arguments:a];
    [t waitUntilExit];
    return [NSData dataWithContentsOfFile:path];
}

// a bounded read at 70 s of video+audio; nil when it did not finish within `seconds`
static NSDictionary *Read(NSString *video, NSString *audio, double seconds) {
    __block NSDictionary *result = nil;
    SFPrebufferRead *request = [SFPrebufferRead new];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDictionary *r = [SFPrebufferReader readURL:[NSURL URLWithString:video] audio:[NSURL URLWithString:audio] position:70 request:request];
        dispatch_async(dispatch_get_main_queue(), ^{ result = r; });
    });
    Until(^BOOL { return result != nil; }, seconds);
    request.cancelled = YES;
    return result;
}

int main(void) { @autoreleasepool {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"ytprebuffer-%d", getpid()]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    gFirstReads = [NSMutableSet new];
    gFiles = @{@"video": Track(dir, @"video"), @"140": Track(dir, @"audio")};
    gStore = [[SFMediaStore alloc] initWithDirectory:[dir stringByAppendingPathComponent:@"store"]];
    SFYTEngine *engine = [SFYTEngine shared];
    NSString *video = [engine.mediaBase stringByAppendingString:@"/s/fixture/video"], *audio = [engine.mediaBase stringByAppendingString:@"/s/fixture/audio/140"];
    gAnswer = @{@"id": @"fixture", @"sid": @"fixture", @"video": video, @"audio": audio, @"duration": @180,
                @"tracks": @{@"video": @{@"id": @"fixture:video", @"total": @([gFiles[@"video"] length]), @"mimeType": @"video/mp4"},
                             @"140": @{@"id": @"fixture:140", @"total": @([gFiles[@"140"] length]), @"mimeType": @"audio/mp4"}}};
    [engine noteOpened:gAnswer];

    NSDictionary *r = Read(video, audio, 40);
    expect(r != nil, "the YouTube-shaped predictive read finishes");
    expect([r[@"reason"] isEqual:@"bounded"] && fabs([r[@"position"] doubleValue] - 70) < 1, "separate video/audio, read at the resume position 70 s");
    [gStore sync];
    long long buffered = [gStore bytesOfItem:@"yt:fixture"], total = (long long)([gFiles[@"video"] length] + [gFiles[@"140"] length]);
    printf("     buffered %lld of %lld bytes\n", buffered, total);
    expect(buffered > 0 && buffered < total, "the predictive bytes are a partial buffer in the persistent store");

    NSUInteger before = gFetched;
    __block BOOL filled = NO;
    __block NSError *fillError;
    dispatch_block_t cancel = [engine fill:@"fixture" progress:^(double p) {} done:^(NSDictionary *res, NSError *e) { fillError = e; filled = YES; }];
    expect(Until(^BOOL { return filled; }, 45), "the manual fill finishes through the production filler");
    if (!filled) cancel();
    [gStore sync];
    expect(!fillError && [gStore itemIsComplete:@"yt:fixture"], "the manual fill completes exactly that buffer");
    expect(gFetched - before == (NSUInteger)(total - buffered), "the manual fill fetches only the missing bytes");

    gFiles = nil;   // the source goes offline
    NSDictionary *stored = [engine storedAnswer:@"fixture"];
    expect(stored != nil && [stored[@"stored"] boolValue], "the complete buffer opens as a stored session");
    before = gFetched;
    r = Read(stored[@"video"], stored[@"audio"], 35);
    expect(r != nil, "the stored session demuxes offline");
    expect([r[@"reason"] isEqual:@"bounded"] && gFetched == before, "the offline read uses the stored bytes, no RPC");

    SFMediaStore *reopened = [[SFMediaStore alloc] initWithDirectory:[dir stringByAppendingPathComponent:@"store"]];
    expect([reopened itemIsComplete:@"yt:fixture"] && [reopened bytesOfItem:@"yt:fixture"] == total, "the complete buffer persists across a store reopen");
    [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    return bad ? 1 : 0;
} }
