// sources:
// SFFadeOpacity (backdrop refinement 2026-11-07): a fade replaces any running opacity animation
// (a fade-in, an earlier fade) instead of stacking on it, sets the target as the model value and
// fades from what is shown; dur 0 is at once; a fade to the value it has adds nothing.
#import "SFCore.h"
#import <QuartzCore/QuartzCore.h>

BOOL SFDevMode = NO;   // main.m's, for SFCore.m
static int fails = 0;
#define CHECK(c, msg) do { if (!(c)) { fprintf(stderr, "FAIL %s (%s:%d)\n", msg, __FILE__, __LINE__); fails++; } } while (0)

static NSArray *opacityAnimations(CALayer *l) {
    NSMutableArray *out = [NSMutableArray new];
    for (NSString *k in [l animationKeys] ?: @[]) {
        CAAnimation *a = [l animationForKey:k];
        if ([a isKindOfClass:[CAPropertyAnimation class]] && [((CAPropertyAnimation *)a).keyPath isEqualToString:@"opacity"]) [out addObject:k];
    }
    return out;
}

int main(void) {
    @autoreleasepool {
        CALayer *l = [CALayer layer];
        CABasicAnimation *in = [CABasicAnimation animationWithKeyPath:@"opacity"];
        in.fromValue = @0; in.toValue = @1; in.duration = 0.3;
        [l addAnimation:in forKey:@"fadein"];   // what SFImageLayer adds for a new picture
        SFFadeOpacity(l, 0, 0.25);               // the focus moves on mid fade-in
        NSArray *keys = opacityAnimations(l);
        CHECK(l.opacity == 0, "target is the model value");
        CHECK(keys.count == 1 && [keys[0] isEqualToString:@"opacity"], "the fade-in is replaced, not stacked on");
        CABasicAnimation *f = (CABasicAnimation *)[l animationForKey:@"opacity"];
        CHECK([f.fromValue floatValue] == 1 && [f.toValue floatValue] == 0, "fades from what is shown (no presentation: the model)");
        SFFadeOpacity(l, 1, 0.3);                // back on the tile mid fade-out
        CHECK(opacityAnimations(l).count == 1 && l.opacity == 1, "turned around: one fade, target 1");
        SFFadeOpacity(l, 0.5, 0);
        CHECK(opacityAnimations(l).count == 0 && l.opacity == 0.5f, "dur 0: at once, no animation");
        SFFadeOpacity(l, 0.5, 0.3);
        CHECK(opacityAnimations(l).count == 0, "already there: nothing to animate");

        // SFShadowPathFromBounds: the shadow takes the rounded bounds (no per-frame alpha pass)
        CALayer *p = [CALayer layer];
        p.bounds = CGRectMake(0, 0, 120, 40); p.cornerRadius = 30;   // more than half the height
        SFShadowPathFromBounds(p);
        CHECK(p.shadowPath && CGRectEqualToRect(CGPathGetBoundingBox(p.shadowPath), p.bounds), "shadow path = the bounds");
        CHECK(CGPathContainsPoint(p.shadowPath, NULL, CGPointMake(60, 20), false) && !CGPathContainsPoint(p.shadowPath, NULL, CGPointMake(1, 1), false),
              "rounded: corners outside, radius clamped to a pill");
    }
    if (fails) { fprintf(stderr, "%d failure(s)\n", fails); return 1; }
    printf("fade ok\n");
    return 0;
}
