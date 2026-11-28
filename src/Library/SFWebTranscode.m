#import "SFWebTranscode.h"
#import "SFSegmentTrack.h"
#import "SFCore.h"
#import "SFWebErrors.h"

static const NSUInteger kAhead = 4;            // segments a job makes beyond the furthest one asked for, then waits
static const NSUInteger kJump = 2;             // a request this far beyond the job's front waits for it (further: a new job)
static const NSTimeInterval kWait = 60;        // a request waits at most this long for its segment
static const NSUInteger kCacheBytes = 48 << 20;
// a job nobody asked anything of for this long stops (dev instances: SOFA_TRANSCODE_IDLE)
static NSTimeInterval IdleStop(void) { return SFDevSeconds(@"SOFA_TRANSCODE_IDLE", 45); }
static const NSInteger kInit = -1;             // a waiter for the init segment

NSString *const SFWebTranscodeBusyMessage = @"Gerade wird schon ein anderes Video für einen Browser umgewandelt – bitte später noch einmal versuchen.";

static __weak id gEncoding;                    // the session that encodes video (one at a time; guarded by the class)
static NSUInteger gJobs;                       // job threads running (tests; guarded by the class)

@interface SFTranscodeWaiter : NSObject
@property (nonatomic) NSInteger segment;
@property (nonatomic) NSTimeInterval since;   // when it was asked for (the newest waiting request is the player's intent)
@property (nonatomic, copy) void (^done)(NSData *data, NSInteger status);
@end
@implementation SFTranscodeWaiter
@end

@implementation SFWebTranscode {
    SFSegmentPlan *_plan;
    NSString *_stream, *_device;
    dispatch_queue_t _q;              // the session's state
    NSData *_init;
    NSMutableDictionary *_cache;      // segment -> NSData
    NSUInteger _cacheBytes, _endedAt;
    SFSegmentJob *_job;
    NSMutableArray *_waiters;
    NSCondition *_gate;               // a job waiting until the player asks further (guards _highest)
    NSUInteger _highest;              // the furthest segment asked for since the job started
    NSString *_failed;
    BOOL _closed, _ended;
    volatile NSTimeInterval _lastUsed;   // the last request (read by the job's pacing and other sessions)
    double _start;                       // where the playback begins (the playlist says so: EXT-X-START)
}

+ (NSUInteger)activeJobsForTesting { @synchronized (self) { return gJobs; } }

+ (instancetype)sessionWithPlan:(SFSegmentPlan *)plan stream:(NSString *)streamID device:(NSString *)device error:(NSString **)why {
    SFWebTranscode *s = [SFWebTranscode new];
    s->_plan = plan; s->_stream = [streamID copy]; s->_device = [device copy];
    if (plan.videoMode != SFSegmentModeEncode) return s;
    SFWebTranscode *other = nil;
    @synchronized (self) {
        other = gEncoding;
        if (other && ![other isIdle] && ![other->_device isEqualToString:device]) {
            SFLog(@"transcode: refused for stream %@ - stream %@ (another device) encodes", [streamID substringToIndex:6], [other->_stream substringToIndex:6]);
            if (why) *why = SFWebTranscodeBusyMessage;
            return nil;
        }
        gEncoding = s;
    }
    if (other) { SFLog(@"transcode: stream %@ takes over the encoder from %@", [streamID substringToIndex:6], [other->_stream substringToIndex:6]); [other close]; }
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _q = dispatch_queue_create("sofa.transcode", DISPATCH_QUEUE_SERIAL);
        _cache = [NSMutableDictionary new];
        _waiters = [NSMutableArray new];
        _gate = [NSCondition new];
        _lastUsed = [NSDate timeIntervalSinceReferenceDate];
    }
    return self;
}

// (read without the queue: a stale answer only delays a refusal or a stop by one check)
- (BOOL)isIdle { return _closed || [NSDate timeIntervalSinceReferenceDate] - _lastUsed > IdleStop(); }

- (double)duration { return _plan.duration; }

- (NSString *)mode {
    NSString *v = _plan.videoMode == SFSegmentModeCopy ? @"copy" : _plan.encoder;
    NSString *a = _plan.audioMode == SFSegmentModeCopy ? @"copy" : _plan.audioMode == SFSegmentModeEncode ? @"aac" : @"none";
    return [NSString stringWithFormat:@"%@+%@", v, a];
}

- (NSString *)playlist {
    NSArray *st = _plan.starts;
    NSMutableString *body = [NSMutableString new];
    double longest = 1;
    for (NSUInteger i = 0; i < st.count; i++) {
        double d = (i + 1 < st.count ? [st[i + 1] doubleValue] : _plan.duration) - [st[i] doubleValue];
        d = MAX(d, 0.1);
        longest = MAX(longest, d);
        [body appendFormat:@"#EXTINF:%.3f,\ns/%lu.m4s\n", d, (unsigned long)i];
    }
    // EXT-X-START: Safari's own player begins at the resume position (it would load segment 0 first, a
    // job there and another one at the position); hls.js is told the same by its startPosition
    NSString *start = _start > 0 ? [NSString stringWithFormat:@"#EXT-X-START:TIME-OFFSET=%.3f,PRECISE=YES\n", _start] : @"";
    return [NSString stringWithFormat:@"#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:%d\n#EXT-X-MEDIA-SEQUENCE:0\n"
            "#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n%@#EXT-X-MAP:URI=\"init.mp4\"\n%@#EXT-X-ENDLIST\n",
            (int)ceil(longest), start, body];
}

#pragma mark Requests

- (void)prepareAt:(double)seconds done:(void (^)(NSString *))done {
    _start = seconds;
    dispatch_async(_q, ^{
        NSUInteger n = [self->_plan segmentAt:seconds];
        [self startJobAt:n];
        [self wait:kInit done:^(NSData *data, NSInteger status) {
            NSString *failure = data ? nil : self->_failed ?: [NSString stringWithFormat:@"no init (%ld)", (long)status];
            SFMain(^{ done(failure); });
        }];
    });
}

- (void)serveInit:(SFHTTPExchange *)x {
    dispatch_async(_q, ^{
        self->_lastUsed = [NSDate timeIntervalSinceReferenceDate];
        if (!self->_init && !self->_job && !self->_failed && !self->_closed) [self startJobAt:self->_highest];
        [self wait:kInit done:[self responder:x]];
    });
}

- (void)serveSegment:(NSUInteger)n to:(SFHTTPExchange *)x {
    dispatch_async(_q, ^{
        self->_lastUsed = [NSDate timeIntervalSinceReferenceDate];
        void (^respond)(NSData *, NSInteger) = [self responder:x];
        if (n >= self->_plan.starts.count || (self->_ended && n >= self->_endedAt && !self->_cache[@(n)])) { respond(nil, 404); return; }
        SFSegmentJob *job = self->_job;
        BOOL cached = self->_cache[@(n)] != nil;
        if (!cached && !self->_failed && !self->_closed && (!job || job.cancelled || n < job.next || n > job.next + kJump)) {
            [self startJobAt:n];   // a seek (or the first request after a stop): from there on
        } else {
            [self->_gate lock];
            if (n > self->_highest) self->_highest = n;
            [self->_gate broadcast];
            [self->_gate unlock];
        }
        SFTranscodeWaiter *w = [self wait:(NSInteger)n done:respond];
        if (!w) return;
        // the player gave the request up (a seek cancels what it loaded ahead): it waits no more - and a
        // job started for it alone gives way to one for a request still waiting (reviewJob)
        __weak SFWebTranscode *weakSelf = self;
        dispatch_queue_t q = self->_q;
        x.onClose = ^{ dispatch_async(q, ^{ [weakSelf waiterGone:w]; }); };
    });
}

- (void)waiterGone:(SFTranscodeWaiter *)w {
    if (![_waiters containsObject:w]) return;
    [_waiters removeObject:w];
    SFLog(@"transcode: stream %@ segment %ld given up by the player after %.1f s", [_stream substringToIndex:6], (long)w.segment,
          [NSDate timeIntervalSinceReferenceDate] - w.since);
    [self reviewJob];
}

// On _q: a request no job will answer - its job gave way to a newer request's, or stopped - gets one,
// once the running job has no one waiting in its reach (the newest request's job goes on first). Without
// this a seek's request waited until the player asked again (2026-11-28: ~30 s): the player's request
// at the new position, then a late one ahead of the old position - whose job replaced the seek's.
- (void)reviewJob {
    if (_closed || _failed) return;
    SFSegmentJob *job = _job;
    BOOL running = job && !job.cancelled;
    SFTranscodeWaiter *orphan = nil;
    for (SFTranscodeWaiter *w in _waiters) {
        if (w.segment == kInit) continue;   // the init comes with every job
        NSUInteger k = (NSUInteger)w.segment;
        if (_cache[@(k)]) continue;
        if (running && k >= job.next && k <= job.next + kJump) return;   // the running job serves someone
        if (!orphan || w.since >= orphan.since) orphan = w;
    }
    if (!orphan) return;
    SFLog(@"transcode: stream %@ segment %ld still waited for (%.1f s) - a job for it", [_stream substringToIndex:6], (long)orphan.segment,
          [NSDate timeIntervalSinceReferenceDate] - orphan.since);
    [self startJobAt:(NSUInteger)orphan.segment];
}

- (void (^)(NSData *, NSInteger))responder:(SFHTTPExchange *)x {
    return ^(NSData *data, NSInteger status) {
        dispatch_async(x.queue, ^{
            if (data) [x respond:200 type:@"video/mp4" body:data];
            else [x respondJSON:status object:status == 410 ? SFWebError(SFWebErrStreamGone, @"Diese Wiedergabe ist beendet.")
                                         : status == 504 ? SFWebError(SFWebErrTimeout, @"Dieser Abschnitt ist noch nicht fertig.")
                                         : status == 404 ? SFWebError(SFWebErrNotFound, @"Diesen Abschnitt gibt es nicht.")
                                         : SFWebError(SFWebErrUpstream, @"Dieser Abschnitt ist nicht verfügbar.")];
        });
    };
}

// On _q: answered at once from what is there (nil), else when the job delivers it (or fails, or the
// time is up) - the waiter
- (SFTranscodeWaiter *)wait:(NSInteger)n done:(void (^)(NSData *, NSInteger))done {
    NSData *have = n == kInit ? _init : _cache[@(n)];
    if (have) { done(have, 200); return nil; }
    if (_closed) { done(nil, 410); return nil; }
    if (_failed) { done(nil, 503); return nil; }
    SFTranscodeWaiter *w = [SFTranscodeWaiter new];
    w.segment = n; w.done = done; w.since = [NSDate timeIntervalSinceReferenceDate];
    [_waiters addObject:w];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWait * NSEC_PER_SEC)), _q, ^{
        if (![self->_waiters containsObject:w]) return;
        [self->_waiters removeObject:w];
        SFLog(@"transcode: segment %ld of stream %@ not ready in %.0f s", (long)n, [self->_stream substringToIndex:6], kWait);
        w.done(nil, 504);
    });
    return w;
}

- (void)answerWaiters:(BOOL (^)(SFTranscodeWaiter *w))match data:(NSData *)data status:(NSInteger)status {
    NSArray *hit = [_waiters filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SFTranscodeWaiter *w, NSDictionary *b) { return match(w); }]];
    [_waiters removeObjectsInArray:hit];
    for (SFTranscodeWaiter *w in hit) w.done(data, status);
}

#pragma mark The job

// On _q: the job from segment n on (the previous one stops)
- (void)startJobAt:(NSUInteger)n {
    [_job cancel];
    [_gate lock];
    _highest = n;
    [_gate broadcast];
    [_gate unlock];
    SFSegmentJob *job = [[SFSegmentJob alloc] initWithPlan:_plan from:n];
    _job = job;
    __weak SFWebTranscode *weakSelf = self;
    __weak SFSegmentJob *weakJob = job;
    dispatch_queue_t q = _q;
    NSCondition *gate = _gate;
    job.onInit = ^(NSData *init) {
        dispatch_sync(q, ^{ [weakSelf job:weakJob madeInit:init]; });
    };
    job.onSegment = ^BOOL(NSUInteger k, NSData *data) {
        __block BOOL current = NO;
        dispatch_sync(q, ^{ current = [weakSelf job:weakJob made:k data:data]; });
        if (!current) return NO;
        // pacing: a few segments ahead of the furthest asked for; a job nobody asks anything of stops
        [gate lock];
        BOOL go = YES;
        for (;;) {
            SFWebTranscode *s = weakSelf;
            SFSegmentJob *j = weakJob;
            if (!s || !j || j.cancelled) { go = NO; break; }
            if (k + 1 <= s->_highest + kAhead) break;
            if ([NSDate timeIntervalSinceReferenceDate] - s->_lastUsed > IdleStop()) {
                SFLog(@"transcode: stream %@ idle - its job stops at segment %lu", [s->_stream substringToIndex:6], (unsigned long)(k + 1));
                go = NO; break;
            }
            [gate waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
        }
        [gate unlock];
        return go;
    };
    job.onEnd = ^(NSString *failure) {
        @synchronized ([SFWebTranscode class]) { gJobs--; }
        dispatch_async(q, ^{ [weakSelf job:weakJob ended:failure]; });
    };
    @synchronized ([SFWebTranscode class]) { gJobs++; }
    SFLog(@"transcode: stream %@ job from segment %lu (%.1f s, %@)", [_stream substringToIndex:6], (unsigned long)n, [_plan.starts[n] doubleValue], self.mode);
    [job start];
}

- (void)job:(SFSegmentJob *)job madeInit:(NSData *)init {
    if (!job || job != _job || _closed) return;
    if (_init && ![_init isEqualToData:init]) {
        // segments of this job would not fit the init the player has: the session fails (the player opens it anew)
        [self fail:@"the init of a new job differs from the first" job:job];
        return;
    }
    _init = init;
    [self answerWaiters:^BOOL(SFTranscodeWaiter *w) { return w.segment == kInit; } data:init status:200];
}

- (BOOL)job:(SFSegmentJob *)job made:(NSUInteger)n data:(NSData *)data {
    if (!job || job != _job || _closed) return NO;
    if (!_cache[@(n)]) { _cache[@(n)] = data; _cacheBytes += data.length; }
    [self answerWaiters:^BOOL(SFTranscodeWaiter *w) { return w.segment == (NSInteger)n; } data:data status:200];
    [self trimCacheKeeping:n];
    [self reviewJob];
    return _job == job;   // it gave way to a job for a request still waiting
}

- (void)job:(SFSegmentJob *)job ended:(NSString *)failure {
    if (!job || job != _job) return;
    _job = nil;
    if (failure) {
        if (_plan.videoMode == SFSegmentModeEncode && ([failure rangeOfString:@"encode"].location != NSNotFound || [failure rangeOfString:_plan.encoder].location != NSNotFound))
            [SFSegmentVideo encoderFailed:_plan.encoder];
        [self fail:failure job:job];
        return;
    }
    if (job.finished) {   // the source's end: nothing after the last segment made
        _ended = YES; _endedAt = job.next;
        [self answerWaiters:^BOOL(SFTranscodeWaiter *w) { return w.segment >= (NSInteger)job.next; } data:nil status:404];
    }
    // (stopped while idle: the next request starts a new job - or one still waiting does)
    [self reviewJob];
}

- (void)fail:(NSString *)why job:(SFSegmentJob *)job {
    SFLog(@"transcode: stream %@ failed: %@", [_stream substringToIndex:6], why);
    _failed = why;
    [job cancel];
    if (_job == job) _job = nil;
    [self answerWaiters:^BOOL(SFTranscodeWaiter *w) { return YES; } data:nil status:503];
}

// Within the bound: segments far behind the furthest asked for go first, then those furthest ahead
- (void)trimCacheKeeping:(NSUInteger)keep {
    while (_cacheBytes > kCacheBytes && _cache.count > 1) {
        NSInteger h = (NSInteger)_highest;
        NSNumber *victim = nil; NSInteger worst = -1;
        for (NSNumber *k in _cache) {
            NSInteger i = k.integerValue;
            if (i == (NSInteger)keep) continue;
            NSInteger score = i < h ? (h - i) * 2 : i - h;
            if (score > worst) { worst = score; victim = k; }
        }
        if (!victim) break;
        _cacheBytes -= [_cache[victim] length];
        [_cache removeObjectForKey:victim];
    }
}

// A paused stream waiting long (SFWebStreams): its made segments go, nothing else changes - the init
// stays (every job's is the same), a later request makes what it asks for again
- (void)dropSegments {
    dispatch_async(_q, ^{
        if (!self->_closed && !self->_job) [self->_plan.inputs drain];   // no source held open meanwhile
        if (self->_closed || self->_job || !self->_cache.count) return;
        SFLog(@"transcode: stream %@ waits - %lu segments dropped (%.1f MB)", [self->_stream substringToIndex:6],
              (unsigned long)self->_cache.count, self->_cacheBytes / 1e6);
        [self->_cache removeAllObjects];
        self->_cacheBytes = 0;
    });
}

- (void)close {
    dispatch_async(_q, ^{
        if (self->_closed) return;
        self->_closed = YES;
        [self->_job cancel];
        self->_job = nil;
        [self->_plan.inputs drain];
        [self->_cache removeAllObjects];
        self->_cacheBytes = 0;
        self->_init = nil;
        [self answerWaiters:^BOOL(SFTranscodeWaiter *w) { return YES; } data:nil status:410];
        [self->_gate lock]; [self->_gate broadcast]; [self->_gate unlock];
    });
    @synchronized ([SFWebTranscode class]) { if (gEncoding == self) gEncoding = nil; }
}
@end
