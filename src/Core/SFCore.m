#import "SFCore.h"

CGFloat SFScale = 1.0;

static dispatch_queue_t gLogQueue;   // set by the first SFLog
void SFLogFlush(void) { if (gLogQueue) dispatch_sync(gLogQueue, ^{}); }

static NSArray *KeyNames(void) {   // in SFKey order
    return @[@"up", @"down", @"left", @"right", @"select", @"menu", @"play", @"selecthold", @"menuhold",
             @"next", @"prev", @"uphold", @"downhold"];
}
NSString *SFKeyName(SFKey key) { NSArray *n = KeyNames(); return key >= 0 && (NSUInteger)key < n.count ? n[key] : nil; }
SFKey SFKeyFromName(NSString *name) { NSUInteger i = [KeyNames() indexOfObject:name.lowercaseString]; return i == NSNotFound ? -1 : (SFKey)i; }

void SFLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static NSFileHandle *fh; static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("sofa.log", DISPATCH_QUEUE_SERIAL);
        gLogQueue = q;
        NSString *p = SFLogPath();
        NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
        if ([a fileSize] > 4 * 1024 * 1024) {
            NSString *old = [p stringByAppendingString:@".1"];
            [[NSFileManager defaultManager] removeItemAtPath:old error:nil];
            [[NSFileManager defaultManager] moveItemAtPath:p toPath:old error:nil];
        }
        if (![[NSFileManager defaultManager] fileExistsAtPath:p])
            [[NSFileManager defaultManager] createFileAtPath:p contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:p];
        [fh seekToEndOfFile];
    });
    NSDate *now = [NSDate date];
    dispatch_async(q, ^{
        static NSDateFormatter *df;
        if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS"; }
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:now], s];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
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

NSDate *SFDateFromISO8601(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length < 10) return nil;
    const char *c = s.UTF8String;
    int y, mo, d, h = 0, mi = 0, n = 0;
    double sec = 0;
    if (sscanf(c, "%4d-%2d-%2d%n", &y, &mo, &d, &n) != 3 || n != 10) return nil;
    NSDateComponents *dc = [NSDateComponents new];
    dc.year = y; dc.month = mo; dc.day = d;
    NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar];
    const char *p = c + 10;
    if (*p != 'T' && *p != ' ') {   // date only: a calendar day in local time
        if (*p) return nil;
        cal.timeZone = [NSTimeZone localTimeZone];
        return [cal dateFromComponents:dc];
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
    dc.hour = h; dc.minute = mi; dc.second = (NSInteger)sec;
    cal.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    NSDate *utc = [cal dateFromComponents:dc];
    return [utc dateByAddingTimeInterval:(sec - floor(sec)) - offset];
}

NSString *SFFormatClock(NSDate *d) {
    static NSDateFormatter *df;
    if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"HH:mm"; }
    return d ? [df stringFromDate:d] : @"";
}

NSString *SFFormatDateShort(NSDate *d) {
    if (!d) return @"";
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *today = [cal startOfDayForDate:[NSDate date]];
    NSDate *day = [cal startOfDayForDate:d];
    NSInteger diff = [cal components:NSCalendarUnitDay fromDate:day toDate:today options:0].day;
    if (diff == 0) return @"Heute";
    if (diff == 1) return @"Gestern";
    if (diff > 1 && diff < 7) return [NSString stringWithFormat:@"vor %ld Tagen", (long)diff];
    // A date in the future is the TV broadcast of an episode the Mediathek already offers ahead
    // (ORF "Vorpremiere"): a bare "10. Nov." looked like a wrong date (2026-11-05)
    if (diff == -1) return @"TV morgen";
    static NSDateFormatter *df, *dfy;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSLocale *de = [NSLocale localeWithLocaleIdentifier:@"de_AT"];
        df = [NSDateFormatter new]; df.locale = de; df.dateFormat = @"d. MMM";
        dfy = [NSDateFormatter new]; dfy.locale = de; dfy.dateFormat = @"d. MMM yyyy";
    });
    @synchronized (df) {
    NSInteger y1 = [cal component:NSCalendarUnitYear fromDate:d];
    NSInteger y2 = [cal component:NSCalendarUnitYear fromDate:today];
    NSString *s = (y1 == y2) ? [df stringFromDate:d] : [dfy stringFromDate:d];
    return diff < 0 ? [@"TV am " stringByAppendingString:s] : s;
    }
}

static NSString *ensureDir(NSString *p) {
    [[NSFileManager defaultManager] createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:nil];
    return p;
}
static NSString *gDataDir, *gInstanceName;   // dev instance only; nil = the real app
static BOOL gDataDirFromEnv;

NSString *SFDevInstanceName(void) { return gInstanceName; }
NSString *SFDevPrivateDir(void) { return gDataDirFromEnv ? ensureDir(gDataDir) : nil; }

NSString *SFLogPath(void) {
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

void SFAnimate(CFTimeInterval dur, dispatch_block_t changes) {
    [CATransaction begin];
    [CATransaction setAnimationDuration:dur];
    [CATransaction setAnimationTimingFunction:
        [CAMediaTimingFunction functionWithControlPoints:0.25 :0.1 :0.25 :1.0]];
    changes();
    [CATransaction commit];
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
