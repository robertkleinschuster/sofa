#import "SFFrameMeter.h"
#import "SFCore.h"
#import <CoreGraphics/CoreGraphics.h>
#import <mach/mach_time.h>

enum { kRing = 512 };                     // frame times kept (8 s at 60 Hz)
static const size_t kStreamW = 256, kStreamH = 144;   // only the timing matters: scale down hard

static dispatch_queue_t gQueue;           // owns the ring
static CGDisplayStreamRef gStream;
static uint64_t gFrames[kRing];
static NSUInteger gCount;                 // frames seen in total (ring index = gCount % kRing)

static double seconds(uint64_t machTime) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)machTime * tb.numer / tb.denom / 1e9;
}

BOOL SFFrameMeterEnabled(void) { return gStream != NULL; }

void SFFrameMeterSetEnabled(BOOL on) {
    if (on == SFFrameMeterEnabled()) return;
    if (!gQueue) gQueue = dispatch_queue_create("sofa.frame-meter", DISPATCH_QUEUE_SERIAL);
    if (!on) {
        CGDisplayStreamStop(gStream); CFRelease(gStream); gStream = NULL;
        SFLog(@"frames: meter off");
        return;
    }
    NSDictionary *props = @{(__bridge NSString *)kCGDisplayStreamMinimumFrameTime: @0,
                            (__bridge NSString *)kCGDisplayStreamShowCursor: @NO};
    gStream = CGDisplayStreamCreateWithDispatchQueue(CGMainDisplayID(), kStreamW, kStreamH, 'BGRA',
                                                     (__bridge CFDictionaryRef)props, gQueue,
        ^(CGDisplayStreamFrameStatus status, uint64_t displayTime, IOSurfaceRef surface, CGDisplayStreamUpdateRef update) {
            if (status != kCGDisplayStreamFrameStatusFrameComplete) return;
            gFrames[gCount++ % kRing] = displayTime;
        });
    if (!gStream || CGDisplayStreamStart(gStream) != kCGErrorSuccess) {
        if (gStream) { CFRelease(gStream); gStream = NULL; }
        SFLog(@"frames: no display stream (no window server access?)");
        return;
    }
    SFLog(@"frames: meter on");
}

void SFFrameMeterMeasure(NSString *what, NSTimeInterval duration) {
    if (!SFFrameMeterEnabled()) return;
    uint64_t start = mach_absolute_time();
    // a frame shown up to a refresh after the end still belongs to the animation
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((duration + 0.1) * NSEC_PER_SEC)), gQueue, ^{
        // first: how long the change took to reach the screen (the commit: main-thread work);
        // gap: the longest wait between two frames once it moved (a dropped frame mid-animation)
        double t0 = seconds(start), t1 = t0 + duration, prev = 0, first = 0, gap = 0, gapAt = 0;
        NSUInteger n = 0;
        for (NSUInteger i = gCount > kRing ? gCount - kRing : 0; i < gCount; i++) {
            double t = seconds(gFrames[i % kRing]);
            if (t <= t0 || t > t1 + 1.0 / 60) continue;
            if (!n) first = t - t0;
            else if (t - prev > gap) { gap = t - prev; gapAt = prev - t0; }
            prev = t; n++;
        }
        if (n && t1 - prev > gap) { gap = t1 - prev; gapAt = prev - t0; }   // frames that stopped before the end
        SFLog(@"frames: %@ %.2f s - %lu frames, %.0f fps, first after %.0f ms, longest gap %.0f ms at %.0f ms", what, duration,
              (unsigned long)n, n / duration, first * 1000, gap * 1000, gapAt * 1000);
    });
}
