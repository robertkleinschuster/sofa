#import "SFHitchMonitor.h"
#import "SFCore.h"
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <pthread.h>

// A watcher thread pings the main queue and measures how long each ping waits to run: the time a
// key press, an animation step or a frame would have waited too. (A run loop observer measuring
// wake-to-sleep counted idle time as busy - its 1-s "stalls" were idle in a sample, 2026-11-07.)
//
// While a ping waits, the watcher samples the main thread's stack every kSample: it suspends the
// thread, walks the frame pointers into preallocated memory and resumes it - no malloc, no locks
// while it is stopped (the main thread may hold either). Symbols are looked up afterwards. The log
// line names the Sofa functions the stall was spent in, so a stall found on the real screen
// points at its code without a profiler attached.
static const NSTimeInterval kHitch = 0.033;      // > 2 frames at 60 Hz: the micro-stutter the user sees
static const NSTimeInterval kPing = 0.050;       // between pings
static const NSTimeInterval kSample = 0.010;     // stack sampling interval during a stall
static const NSTimeInterval kKeyWindow = 1.0;    // a stall this soon after a key press is "after" it
enum { kMaxSamples = 256, kMaxDepth = 64, kTopFunctions = 3 };

typedef struct { uintptr_t pc[kMaxDepth]; int depth; } SFStack;

static mach_port_t gMain;
static uintptr_t gStackLo, gStackHi;

// A frame record at `a`: [a] the caller's frame, higher up the same stack; [a+8] a return address,
// which points into code, not into the stack.
static BOOL isFrame(uintptr_t a) {
    if (a < gStackLo || a + 16 > gStackHi || (a & 7)) return NO;
    uintptr_t next = ((uintptr_t *)a)[0], ret = ((uintptr_t *)a)[1];
    return next > a && next + 16 <= gStackHi && !(next & 7) && ret && (ret < gStackLo || ret >= gStackHi);
}

// The first frame record at or above `from`, within a small window. Some leaf code keeps no
// standard frame - on 10.9 __commpage_gettimeofday (every NSDate call) moves rbp below its locals,
// and mach_absolute_time links to that broken frame: a sampled NSDate loop lost its caller in 88
// of 200 samples, 2 of 200 with this scan (frameless objc_msgSend; probe 2026-11-07). The caller's
// record lies a few words up.
static uintptr_t scanForFrame(uintptr_t from) {
    for (uintptr_t a = from & ~(uintptr_t)7, end = a + 64 * 8; a < end; a += 8)
        if (isFrame(a)) return a;
    return 0;
}

// One stack of the (suspended) main thread: pc, then return addresses up the rbp chain.
static void captureMain(SFStack *s) {
    s->depth = 0;
    if (thread_suspend(gMain) != KERN_SUCCESS) return;
    x86_thread_state64_t st;
    mach_msg_type_number_t n = x86_THREAD_STATE64_COUNT;
    if (thread_get_state(gMain, x86_THREAD_STATE64, (thread_state_t)&st, &n) == KERN_SUCCESS) {
        s->pc[s->depth++] = (uintptr_t)st.__rip;
        uintptr_t fp = isFrame((uintptr_t)st.__rbp) ? (uintptr_t)st.__rbp : scanForFrame((uintptr_t)st.__rsp);
        while (fp && s->depth < kMaxDepth) {
            s->pc[s->depth++] = ((uintptr_t *)fp)[1];
            uintptr_t next = ((uintptr_t *)fp)[0];
            // a broken link: the record below is real, the frame it points to is not standard -
            // look above it (the outermost frame, start, points outside the stack and ends the chain)
            fp = isFrame(next) ? next : next > fp && next < gStackHi ? scanForFrame(next) : 0;
        }
    }
    thread_resume(gMain);
}

// "-[SFTile refreshDownload]" for an address inside Sofa itself, nil elsewhere.
static NSString *ownSymbol(uintptr_t pc, const void *ownBase) {
    Dl_info info;
    if (!dladdr((const void *)(pc - 1), &info) || info.dli_fbase != ownBase || !info.dli_sname) return nil;
    return @(info.dli_sname);
}

// "-[A b] 7x via -[NSFileManager removeItemAtPath:error:], -[C d] 3x of 10 samples (leaf __open)":
// per sample the innermost Sofa frame, counted - the code that caused the stall, even when the time
// went into a framework - and the call it was in most often (the frame just inside it).
// " via X" for the callee seen most often, "" without one.
static NSString *viaOf(NSCountedSet *callees) {
    NSString *top = nil;
    for (NSString *c in callees) if (!top || [callees countForObject:c] > [callees countForObject:top]) top = c;
    return top ? [@" via " stringByAppendingString:top] : @"";
}

static NSString *describe(const SFStack *samples, int count) {
    if (!count) return nil;
    const void *ownBase = _dyld_get_image_header(0);
    NSCountedSet *own = [NSCountedSet new], *leaves = [NSCountedSet new];
    NSMutableDictionary *via = [NSMutableDictionary new];   // own symbol -> callees
    for (int i = 0; i < count; i++) {
        const SFStack *s = &samples[i];
        if (!s->depth) continue;
        Dl_info info;
        if (dladdr((const void *)s->pc[0], &info) && info.dli_sname) [leaves addObject:@(info.dli_sname)];
        for (int d = 0; d < s->depth; d++) {
            NSString *sym = ownSymbol(s->pc[d], ownBase);
            if (!sym) continue;
            [own addObject:sym];
            Dl_info ci;
            if (d > 0 && dladdr((const void *)(s->pc[d - 1] - (d - 1 ? 1 : 0)), &ci) && ci.dli_sname) {
                if (!via[sym]) via[sym] = [NSCountedSet new];
                [via[sym] addObject:@(ci.dli_sname)];
            }
            break;
        }
    }
    NSComparator byCount = ^(id a, id b) { return [@([own countForObject:b]) compare:@([own countForObject:a])]; };
    NSArray *top = [own.allObjects sortedArrayUsingComparator:byCount];
    NSMutableArray *parts = [NSMutableArray new];
    for (NSString *sym in [top subarrayWithRange:NSMakeRange(0, MIN(top.count, (NSUInteger)kTopFunctions))])
        [parts addObject:[NSString stringWithFormat:@"%@ %lux%@", sym, (unsigned long)[own countForObject:sym], viaOf(via[sym])]];
    NSString *leaf = [[leaves.allObjects sortedArrayUsingComparator:^(id a, id b) {
        return [@([leaves countForObject:b]) compare:@([leaves countForObject:a])]; }] firstObject];
    return [NSString stringWithFormat:@"%@ of %d samples%@", parts.count ? [parts componentsJoinedByString:@", "] : @"no Sofa frame",
            count, leaf ? [NSString stringWithFormat:@" (leaf %@)", leaf] : @""];
}

void SFHitchMonitorStart(void (^lastKey)(NSString **, NSTimeInterval *)) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gMain = pthread_mach_thread_np(pthread_self());
        gStackHi = (uintptr_t)pthread_get_stackaddr_np(pthread_self());
        gStackLo = gStackHi - pthread_get_stacksize_np(pthread_self());
        void (^key)(NSString **, NSTimeInterval *) = [lastKey copy];
        NSThread *t = [[NSThread alloc] initWithTarget:[NSBlockOperation blockOperationWithBlock:^{
            SFStack *samples = calloc(kMaxSamples, sizeof(SFStack));
            dispatch_semaphore_t ran = dispatch_semaphore_create(0);
            NSTimeInterval lastLog = 0;
            NSUInteger quiet = 0;   // stalls not logged since the last line (at most one line per second)
            while (YES) {
                NSTimeInterval sent = [NSDate timeIntervalSinceReferenceDate];
                dispatch_async(dispatch_get_main_queue(), ^{ dispatch_semaphore_signal(ran); });
                int count = 0;
                if (dispatch_semaphore_wait(ran, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHitch * NSEC_PER_SEC)))) {
                    do captureMain(&samples[count < kMaxSamples ? count++ : kMaxSamples - 1]);   // a long stall keeps its latest stack
                    while (dispatch_semaphore_wait(ran, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSample * NSEC_PER_SEC))));
                }
                NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate], waited = now - sent;
                if (waited >= kHitch) {
                    if (now - lastLog < 1) quiet++;
                    else {
                        __block NSString *name = nil; __block NSTimeInterval at = 0;
                        if (key) dispatch_sync(dispatch_get_main_queue(), ^{ key(&name, &at); });
                        NSString *after = name && now - at < waited + kKeyWindow ? [NSString stringWithFormat:@" after key %@", name] : @"";
                        NSString *where = describe(samples, count);
                        SFLog(@"hitch: main thread blocked %.0f ms%@%@%@", waited * 1000, after,
                              quiet ? [NSString stringWithFormat:@" (+%lu more since the last line)", (unsigned long)quiet] : @"",
                              where ? [@" in " stringByAppendingString:where] : @"");
                        lastLog = now; quiet = 0;
                    }
                }
                usleep((useconds_t)(kPing * 1e6));
            }
        }] selector:@selector(start) object:nil];
        t.name = @"sofa.hitch-monitor";
        [t start];
    });
}
