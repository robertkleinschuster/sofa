#import "SFYTPointer.h"
#include <X11/Xlib.h>
#include <X11/extensions/XTest.h>
#include <math.h>
#include <unistd.h>

static double Uniform(double lo, double hi) { return lo + (hi - lo) * (arc4random_uniform(1u << 30) / (double)(1u << 30)); }
static void Pause(double seconds) { usleep((useconds_t)(seconds * 1e6)); }

@implementation SFYTPointer {
    dispatch_queue_t _queue;
}

- (instancetype)initWithDisplay:(NSString *)display {
    if ((self = [super init])) {
        _display = [display copy];
        _queue = dispatch_queue_create("sofa.yt.pointer", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)clickInRect:(CGRect)rect done:(void (^)(BOOL))done {
    NSString *name = _display;
    dispatch_async(_queue, ^{
        BOOL ok = Click(name, rect);
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(ok); });
    });
}

// One gesture: path, hover, press, release. Blocking, on the pointer's queue.
static BOOL Click(NSString *name, CGRect rect) {
    Display *d = XOpenDisplay(name.UTF8String);
    if (!d) return NO;
    int ev, err, major, minor;
    if (!XTestQueryExtension(d, &ev, &err, &major, &minor)) { XCloseDisplay(d); return NO; }
    // from where the pointer is now
    Window root = DefaultRootWindow(d), r, c;
    int x0 = 0, y0 = 0, wx, wy;
    unsigned int mask;
    XQueryPointer(d, root, &r, &c, &x0, &y0, &wx, &wy, &mask);
    // to a point in the middle 60 % of the target: never on its edge
    double tx = CGRectGetMinX(rect) + rect.size.width * Uniform(0.2, 0.8);
    double ty = CGRectGetMinY(rect) + rect.size.height * Uniform(0.25, 0.75);
    double dx = tx - x0, dy = ty - y0, dist = hypot(dx, dy);
    // a gentle arc (control point off the straight line), duration growing with the distance
    double bend = Uniform(-0.15, 0.15) * dist;
    double cx = x0 + dx / 2 - dy / (dist ?: 1) * bend, cy = y0 + dy / 2 + dx / (dist ?: 1) * bend;
    double duration = MIN(0.9, 0.25 + dist / 2500) * Uniform(0.85, 1.15);
    int steps = MAX(8, (int)(duration / 0.014));
    for (int i = 1; i <= steps; i++) {
        double t = (double)i / steps, e = t * t * (3 - 2 * t);   // ease in and out
        double px = (1 - e) * (1 - e) * x0 + 2 * (1 - e) * e * cx + e * e * tx;
        double py = (1 - e) * (1 - e) * y0 + 2 * (1 - e) * e * cy + e * e * ty;
        XTestFakeMotionEvent(d, -1, (int)lround(px), (int)lround(py), CurrentTime);
        XFlush(d);
        Pause(duration / steps * Uniform(0.7, 1.3));
    }
    Pause(Uniform(0.08, 0.25));   // hover
    XTestFakeButtonEvent(d, Button1, True, CurrentTime);
    XFlush(d);
    Pause(Uniform(0.06, 0.13));
    XTestFakeButtonEvent(d, Button1, False, CurrentTime);
    XSync(d, False);
    XCloseDisplay(d);
    return YES;
}

@end
