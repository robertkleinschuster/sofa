#import "SFCore.h"
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>

CGFloat SFScale = 1.0;

static NSArray *KeyNames(void) {   // in SFKey order
    return @[@"up", @"down", @"left", @"right", @"select", @"menu", @"play", @"selecthold", @"menuhold",
             @"next", @"prev", @"uphold", @"downhold"];
}
NSString *SFKeyName(SFKey key) { NSArray *n = KeyNames(); return key >= 0 && (NSUInteger)key < n.count ? n[key] : nil; }
SFKey SFKeyFromName(NSString *name) { NSUInteger i = [KeyNames() indexOfObject:name.lowercaseString]; return i == NSNotFound ? -1 : (SFKey)i; }

// The log in memory, written together (user 2026-11-17: no disk writes while idle or resting - every
// small write is several head moves on this SMR disk): lines wait up to SFLogSetDelay seconds (30 s
// awake, 10 min resting - the shell sets it) and go out at once when they report a failure, when
// 64 KB are waiting, at SFLogFlush (exit, update) - and from a crash handler (the lines just before
// a crash are the ones that matter). Rotated past 4 MB (one previous file, .1), while running too.
static const unsigned long long kLogRotateBytes = 4 * 1024 * 1024;
enum { kLogBuf = 256 * 1024, kLogSoon = 64 * 1024 };
static dispatch_queue_t gLogQueue;          // set by the first SFLog; everything below on it
static char gLogBuf[kLogBuf];
static volatile size_t gLogLen;             // also read by the crash handler
static volatile int gLogFD = -1;
static NSString *gLogPath;
static unsigned long long gLogSize;
static NSTimeInterval gLogDelay = 30;
static NSUInteger gLogFlushGen;             // a pending delayed flush is moot after a flush

static void SFLogOpen(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([[fm attributesOfItemAtPath:gLogPath error:nil] fileSize] > kLogRotateBytes) {
        NSString *old = [gLogPath stringByAppendingString:@".1"];
        [fm removeItemAtPath:old error:nil];
        [fm moveItemAtPath:gLogPath toPath:old error:nil];
    }
    gLogFD = open(gLogPath.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
    struct stat st;
    gLogSize = gLogFD >= 0 && fstat(gLogFD, &st) == 0 ? (unsigned long long)st.st_size : 0;
}
static void SFLogWriteNow(void) {   // on gLogQueue
    gLogFlushGen++;
    if (!gLogLen) return;
    size_t off = 0;
    while (gLogFD >= 0 && off < gLogLen) { ssize_t w = write(gLogFD, gLogBuf + off, gLogLen - off); if (w <= 0) break; off += (size_t)w; }
    gLogSize += gLogLen;
    gLogLen = 0;
    if (gLogSize > kLogRotateBytes) { close(gLogFD); gLogFD = -1; SFLogOpen(); }
}
// async-signal-safe: write what waits, then the signal goes on to the default handler (crash report;
// SIGTERM ends as before)
static void SFLogCrashed(int sig) {
    if (gLogFD >= 0 && gLogLen) { ssize_t w = write(gLogFD, gLogBuf, gLogLen); (void)w; }
    signal(sig, SIG_DFL);
    raise(sig);
}
void SFLogFlush(void) { if (gLogQueue) dispatch_sync(gLogQueue, ^{ SFLogWriteNow(); }); }
// the last way out (a hung main thread or log queue): what waits, written without the queue
void SFLogWriteNowUnsafe(void) { if (gLogFD >= 0 && gLogLen) { ssize_t w = write(gLogFD, gLogBuf, gLogLen); (void)w; gLogLen = 0; } }
// dev instances and tests write at once: their scripts wait for log lines
// a change writes what waits at once: going to rest the lines before it matter, waking a pending
// 10-min flush must not hold the new lines (it is moot after this write)
void SFLogSetDelay(NSTimeInterval seconds) {
    if (gLogQueue && !SFDevMode) dispatch_async(gLogQueue, ^{ if (gLogDelay != seconds) SFLogWriteNow(); gLogDelay = MAX(0, seconds); });
}
static void SFLogAtExit(void) { SFLogFlush(); }

static BOOL SFLogUrgent(NSString *s) {
    for (NSString *w in @[@"fail", @"error", @"crash", @"exited", @"unresponsive", @"killed", @"abort"])
        if ([s rangeOfString:w options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}

void SFLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLogQueue = dispatch_queue_create("sofa.log", DISPATCH_QUEUE_SERIAL);
        dispatch_sync(gLogQueue, ^{ gLogPath = SFLogPath(); SFLogOpen(); if (SFDevMode) gLogDelay = 0; });
        atexit(SFLogAtExit);
        for (int sig = 1; sig < NSIG; sig++)
            if (sig == SIGSEGV || sig == SIGBUS || sig == SIGILL || sig == SIGABRT || sig == SIGFPE || sig == SIGTRAP || sig == SIGTERM) {
                struct sigaction cur;   // a SIGTERM the app handles itself (the shell: an orderly quit) stays its own
                if (sig == SIGTERM && sigaction(sig, NULL, &cur) == 0 && cur.sa_handler != SIG_DFL) continue;
                signal(sig, SFLogCrashed);
            }
    });
    NSDate *now = [NSDate date];
    BOOL urgent = SFLogUrgent(s);
    dispatch_async(gLogQueue, ^{
        static NSDateFormatter *df;
        if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS"; }
        NSData *d = [[NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:now], s] dataUsingEncoding:NSUTF8StringEncoding];
        if (gLogLen + d.length > kLogBuf) SFLogWriteNow();
        if (d.length > kLogBuf) d = [d subdataWithRange:NSMakeRange(0, kLogBuf)];
        memcpy(gLogBuf + gLogLen, d.bytes, d.length);
        gLogLen += d.length;
        if (urgent || gLogDelay <= 0 || gLogLen >= kLogSoon) { SFLogWriteNow(); return; }
        if (gLogLen == d.length) {   // the first line waiting: one delayed write for all that follow
            NSUInteger gen = gLogFlushGen;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gLogDelay * NSEC_PER_SEC)), gLogQueue, ^{ if (gen == gLogFlushGen) SFLogWriteNow(); });
        }
    });
#ifdef DEBUG
    fprintf(stderr, "%s\n", s.UTF8String);
#endif
}

NSColor *SFHex(uint32_t rgb) { return SFHexA(rgb, 1.0); }
NSColor *SFHexA(uint32_t rgb, CGFloat a) {
    return [NSColor colorWithDeviceRed:((rgb >> 16) & 0xff) / 255.0
                                 green:((rgb >> 8) & 0xff) / 255.0
                                  blue:(rgb & 0xff) / 255.0 alpha:a];
}

NSString *SFFormatDuration(NSTimeInterval secs) {
    if (!(secs > 0) || isinf(secs)) return @"";
    long s = (long)llround(secs);
    if (s >= 3600) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", s / 3600, (s / 60) % 60, s % 60];
    return [NSString stringWithFormat:@"%ld:%02ld", s / 60, s % 60];
}

NSString *SFDotJoinN(NSUInteger n, ...) {
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:n];
    va_list ap;
    va_start(ap, n);
    for (NSUInteger i = 0; i < n; i++) {
        NSString *p = [va_arg(ap, NSString *) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (p.length) [a addObject:p];   // API strings carry stray spaces ("WDR ") -> uneven gaps around the dot
    }
    va_end(ap);
    return [a componentsJoinedByString:@" · "];
}

NSArray *SFInterleave(NSArray *lists, NSUInteger max, id (^key)(id)) {
    NSMutableArray *r = [NSMutableArray new];
    NSMutableSet *seen = [NSMutableSet new];
    for (NSUInteger k = 0; r.count < max; k++) {
        BOOL any = NO;
        for (NSArray *l in lists) {
            if (k >= l.count) continue;
            any = YES;
            id e = l[k], kk = key(e);
            if (!kk || [seen containsObject:kk]) continue;
            [seen addObject:kk];
            [r addObject:e];
            if (r.count >= max) break;
        }
        if (!any) break;
    }
    return r;
}

// Plain C time arithmetic (timegm/mktime): an NSCalendar per call cost ~15 ms - a home refresh
// parsing 63 dates blocked the main thread for a second (hitch 2026-11-08).
NSDate *SFDateFromISO8601(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length < 10) return nil;
    const char *c = s.UTF8String;
    int y, mo, d, h = 0, mi = 0, n = 0;
    double sec = 0;
    if (sscanf(c, "%4d-%2d-%2d%n", &y, &mo, &d, &n) != 3 || n != 10) return nil;
    struct tm t = {0};
    t.tm_year = y - 1900; t.tm_mon = mo - 1; t.tm_mday = d;
    const char *p = c + 10;
    if (*p != 'T' && *p != ' ') {   // date only: a calendar day in local time
        if (*p) return nil;
        t.tm_isdst = -1;
        return [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)mktime(&t)];
    }
    p++;
    int m = 0;
    if (sscanf(p, "%2d:%2d%n", &h, &mi, &m) != 2 || m != 5) return nil;
    p += 5;
    if (*p == ':') { int k = 0; if (sscanf(p + 1, "%lf%n", &sec, &k) != 1) return nil; p += 1 + k; }   // seconds, fraction
    NSInteger offset = 0;   // seconds east of UTC
    if (*p == '+' || *p == '-') {
        int oh = 0, om = 0;
        if (sscanf(p + 1, "%2d:%2d", &oh, &om) < 2 && sscanf(p + 1, "%2d%2d", &oh, &om) < 1) return nil;
        offset = (oh * 3600 + om * 60) * (*p == '-' ? -1 : 1);
    } else if (*p && *p != 'Z') return nil;
    t.tm_hour = h; t.tm_min = mi; t.tm_sec = 0;
    return [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)timegm(&t) + sec - offset];
}

NSString *SFFormatClock(NSDate *d) {
    static NSDateFormatter *df;
    if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"HH:mm"; }
    return d ? [df stringFromDate:d] : @"";
}

NSArray *SFRangesIntersect(NSArray *a, NSArray *b) {
    NSMutableArray *out = [NSMutableArray new];
    NSUInteger i = 0, j = 0;
    while (i < a.count && j < b.count) {
        double s = MAX([a[i][0] doubleValue], [b[j][0] doubleValue]), e = MIN([a[i][1] doubleValue], [b[j][1] doubleValue]);
        if (e > s) [out addObject:@[@(s), @(e)]];
        if ([a[i][1] doubleValue] < [b[j][1] doubleValue]) i++; else j++;
    }
    return out;
}

void SFRangesAppend(NSMutableArray *r, double start, double end) {
    if (end <= start) return;
    if (r.count && [[r.lastObject lastObject] doubleValue] >= start) r[r.count - 1] = @[r.lastObject[0], @(MAX(end, [[r.lastObject lastObject] doubleValue]))];
    else [r addObject:@[@(start), @(end)]];
}

double SFRangesSeconds(NSArray *r, double limit) {
    double n = 0;
    for (NSArray *x in r) n += MAX(0, MIN(limit, [x[1] doubleValue]) - MAX(0, [x[0] doubleValue]));
    return n;
}

NSString *SFFormatBytes(unsigned long long b) {
    if (b < 1000000000ULL) return [NSString stringWithFormat:@"%llu MB", b / 1000000ULL];
    return [NSString stringWithFormat:@"%.0f GB", b / 1e9];
}

// the local calendar day of t: days since 1970-01-01 local time (the zone's offset at t, so a
// DST change is exact) - comparing two of these is what "Heute"/"Gestern" needs, no ICU calendar
static long LocalDay(NSTimeInterval t, NSTimeZone *tz) {
    return (long)floor((t + [tz secondsFromGMTForDate:[NSDate dateWithTimeIntervalSince1970:t]]) / 86400);
}

static NSString *DateLabel(long diff, NSDate *d, NSDate *now, NSTimeZone *tz) {
    if (diff == 0) return @"Heute";
    if (diff == 1) return @"Gestern";
    if (diff > 1 && diff < 7) return [NSString stringWithFormat:@"vor %ld Tagen", diff];
    // A date in the future is the TV broadcast of an episode the Mediathek already offers ahead
    // (ORF "Vorpremiere"): a bare "10. Nov." looked like a wrong date (2026-11-05)
    if (diff == -1) return @"TV morgen";
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"de_AT"];
    f.timeZone = tz;
    f.dateFormat = @"yyyy";
    BOOL sameYear = [[f stringFromDate:d] isEqual:[f stringFromDate:now]];
    f.dateFormat = sameYear ? @"d. MMM" : @"d. MMM yyyy";
    NSString *s = [f stringFromDate:d];
    return diff < 0 ? [@"TV am " stringByAppendingString:s] : s;
}

NSString *SFFormatDateShortAt(NSDate *d, NSDate *now) {
    if (!d) return @"";
    // a home refresh labels hundreds of tiles on the main thread: one label per calendar day,
    // remembered until the day (or the zone) changes (hitch 2026-11-08: ~150 ms per refresh)
    static NSMutableDictionary *cache;
    static long cachedToday;
    static NSString *cachedZone;   // its name (localTimeZone is a proxy: the object always equals the current one)
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    NSTimeZone *tz = [NSTimeZone localTimeZone];
    long today = LocalDay(now.timeIntervalSince1970, tz), day = LocalDay(d.timeIntervalSince1970, tz);
    @synchronized (lock) {
        if (!cache || today != cachedToday || ![tz.name isEqual:cachedZone]) {
            cache = [NSMutableDictionary new]; cachedToday = today; cachedZone = [tz.name copy];
        }
        NSString *s = cache[@(day)];
        if (!s) cache[@(day)] = s = DateLabel(today - day, d, now, tz);
        return s;
    }
}

NSString *SFFormatDateShort(NSDate *d) { return SFFormatDateShortAt(d, [NSDate date]); }

static NSString *ensureDir(NSString *p) {
    [[NSFileManager defaultManager] createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:nil];
    return p;
}
static NSString *gDataDir, *gInstanceName;   // dev instance only; nil = the real app
static BOOL gDataDirFromEnv;

NSString *SFDevInstanceName(void) { return gInstanceName; }
NSString *SFDevPrivateDir(void) { return gDataDirFromEnv ? ensureDir(gDataDir) : nil; }

NSString *SFLogPath(void) {
#ifdef SF_UNIT_TEST
    // a unit test (tools/test-units builds SFCore with SF_UNIT_TEST) never writes the real app's log:
    // its own file, shown with the test's output when it fails
    NSString *unit = [NSProcessInfo processInfo].environment[@"SOFA_UNIT_LOG"];
    return unit.length ? unit : [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"sofa-unit-%d.log", getpid()]];
#endif
    if (SFDevPrivateDir()) return [gDataDir stringByAppendingPathComponent:@"sofa.log"];
    NSString *name = gInstanceName ? [NSString stringWithFormat:@"Sofa-dev-%@.log", gInstanceName] : @"Sofa.log";
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"] stringByAppendingPathComponent:name];
}

void SFSetDevInstance(NSString *instance) {
    gInstanceName = instance.length ? instance : @"view";
    NSString *env = [NSProcessInfo processInfo].environment[@"SOFA_DATA_DIR"];
    gDataDirFromEnv = env.length > 0;
    gDataDir = env.length ? env : [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Sofa-dev"]
                                    stringByAppendingPathComponent:instance.length ? instance : @"view"];
}

NSString *SFAppSupportDir(void) {
    return ensureDir(gDataDir ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Sofa"]);
}
NSString *SFSharedCacheDir(void) {
    return ensureDir([NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/Sofa"]);
}
NSString *SFCacheDir(void) {
    return gDataDir ? ensureDir([gDataDir stringByAppendingPathComponent:@"Caches"]) : SFSharedCacheDir();
}

BOOL SFReducedMotion = NO;
void SFAnimate(CFTimeInterval dur, dispatch_block_t changes) {
    if (SFReducedMotion) { SFNoAnimate(changes); return; }
    [CATransaction begin];
    [CATransaction setAnimationDuration:dur];
    [CATransaction setAnimationTimingFunction:
        [CAMediaTimingFunction functionWithControlPoints:0.25 :0.1 :0.25 :1.0]];
    changes();
    [CATransaction commit];
}
void SFShadowPathFromBounds(CALayer *layer) {
    CGFloat r = MIN(layer.cornerRadius, MIN(layer.bounds.size.width, layer.bounds.size.height) / 2);
    CGPathRef p = CGPathCreateWithRoundedRect(layer.bounds, r, r, NULL);
    layer.shadowPath = p;
    CGPathRelease(p);
}

void SFFadeOpacity(CALayer *layer, float to, CFTimeInterval dur) {
    CALayer *shown = layer.presentationLayer;
    float from = shown ? shown.opacity : layer.opacity;
    for (NSString *key in [layer animationKeys] ?: @[]) {
        CAAnimation *a = [layer animationForKey:key];
        if ([a isKindOfClass:[CAPropertyAnimation class]] && [((CAPropertyAnimation *)a).keyPath isEqualToString:@"opacity"]) [layer removeAnimationForKey:key];
    }
    SFNoAnimate(^{ layer.opacity = to; });
    if (dur <= 0 || from == to) return;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @(from); fade.toValue = @(to); fade.duration = dur;
    fade.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.25 :0.1 :0.25 :1.0];
    [layer addAnimation:fade forKey:@"opacity"];
}

void SFNoAnimate(dispatch_block_t changes) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    changes();
    [CATransaction commit];
}

#import <objc/message.h>
// Video layers render black in renderInContext: (mpv's CAOpenGLLayer). They are
// hidden while rendering; one that can produce its frame (mpv: devCopyFrameOfSize:, dev mode) is
// drawn in its place, so dev screenshots and the dev stream show the real picture.
static void collectPlayerLayers(CALayer *l, NSMutableArray *out) {
    if ([l respondsToSelector:@selector(devCopyFrameOfSize:)]) { [out addObject:l]; return; }
    for (CALayer *s in l.sublayers) collectPlayerLayers(s, out);
}
void SFRenderLayerTree(CALayer *root, CGContextRef ctx) {
    NSMutableArray *pl = [NSMutableArray new];
    collectPlayerLayers(root, pl);
    NSMutableArray *states = [NSMutableArray new];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *l in pl) { [states addObject:@(l.hidden)]; l.hidden = YES; }
    // a frame drawn into ctx beforehand would be covered by opaque backgrounds (the black video
    // host), so the frame goes into a temporary plain layer that takes the video layer's place
    NSMutableArray *stand = [NSMutableArray new];
    for (NSUInteger i = 0; i < pl.count; i++) {
        CALayer *l = pl[i];
        if ([states[i] boolValue] || !l.superlayer || ![l respondsToSelector:@selector(devCopyFrameOfSize:)]) continue;
        CGImageRef img = ((CGImageRef (*)(id, SEL, CGSize))objc_msgSend)(l, @selector(devCopyFrameOfSize:), l.bounds.size);
        if (!img) continue;
        CALayer *f = [CALayer layer];
        f.frame = l.frame;
        f.contents = (__bridge id)img;
        f.contentsGravity = kCAGravityResize;
        CGImageRelease(img);
        [l.superlayer insertSublayer:f above:l];
        [stand addObject:f];
    }
    [root renderInContext:ctx];
    for (CALayer *f in stand) [f removeFromSuperlayer];
    for (NSUInteger i = 0; i < pl.count; i++) [pl[i] setHidden:[states[i] boolValue]];
    [CATransaction commit];
}

NSString *SFDevEnv(NSString *name) {
    NSString *v = SFDevMode ? [NSProcessInfo processInfo].environment[name] : nil;
    return v.length ? v : nil;
}

NSTimeInterval SFDevSeconds(NSString *name, NSTimeInterval dflt) {
    double t = [SFDevEnv(name) doubleValue];
    return t > 0 ? t : dflt;
}

BOOL SFSimulatedOffline(void) {
    static int v = -1;
    if (v < 0) v = SFDevEnv(@"SOFA_OFFLINE") != nil;
    return v == 1;
}

NSString *SFJSONString(id obj) {
    NSData *d = obj ? [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil] : nil;
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
}

id SFJSONParse(NSString *text) {
    NSData *d = [text isKindOfClass:[NSString class]] ? [text dataUsingEncoding:NSUTF8StringEncoding] : nil;
    return d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
}
