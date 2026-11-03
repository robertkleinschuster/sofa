#import "SFCore.h"

CGFloat SFScale = 1.0;

NSString *SFLogFileName = @"Sofa.log";
void SFLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static NSFileHandle *fh; static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("sofa.log", DISPATCH_QUEUE_SERIAL);
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
        NSString *p = [dir stringByAppendingPathComponent:SFLogFileName ?: @"Sofa.log"];
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

NSString *SFFormatDateShort(NSDate *d) {
    if (!d) return @"";
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *today = [cal startOfDayForDate:[NSDate date]];
    NSDate *day = [cal startOfDayForDate:d];
    NSInteger diff = [cal components:NSCalendarUnitDay fromDate:day toDate:today options:0].day;
    if (diff == 0) return @"Heute";
    if (diff == 1) return @"Gestern";
    if (diff > 1 && diff < 7) return [NSString stringWithFormat:@"vor %ld Tagen", (long)diff];
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
    return (y1 == y2) ? [df stringFromDate:d] : [dfy stringFromDate:d];
    }
}

static NSString *ensureDir(NSString *p) {
    [[NSFileManager defaultManager] createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:nil];
    return p;
}
NSString *SFAppSupportDir(void) {
    return ensureDir([NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Sofa"]);
}
NSString *SFCacheDir(void) {
    return ensureDir([NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/Sofa"]);
}

void SFAnimate(CFTimeInterval dur, dispatch_block_t changes) {
    [CATransaction begin];
    [CATransaction setAnimationDuration:dur];
    [CATransaction setAnimationTimingFunction:
        [CAMediaTimingFunction functionWithControlPoints:0.25 :0.1 :0.25 :1.0]];
    changes();
    [CATransaction commit];
}
void SFNoAnimate(dispatch_block_t changes) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    changes();
    [CATransaction commit];
}

#import <AVFoundation/AVFoundation.h>
static void collectPlayerLayers(CALayer *l, NSMutableArray *out) {
    if ([l isKindOfClass:[AVPlayerLayer class]]) { [out addObject:l]; return; }
    for (CALayer *s in l.sublayers) collectPlayerLayers(s, out);
}
void SFRenderLayerTree(CALayer *root, CGContextRef ctx) {
    NSMutableArray *pl = [NSMutableArray new];
    collectPlayerLayers(root, pl);
    NSMutableArray *states = [NSMutableArray new];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *l in pl) { [states addObject:@(l.hidden)]; l.hidden = YES; }
    [root renderInContext:ctx];
    for (NSUInteger i = 0; i < pl.count; i++) [pl[i] setHidden:[states[i] boolValue]];
    [CATransaction commit];
}
