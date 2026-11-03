#import "SFIconArt.h"
#import "SFTheme.h"

NSString *SFIconArt(NSString *symbol, NSString *source) {
    SFTheme *t = [SFTheme themeNamed:source ?: @"home"];
    NSString *path = [SFCacheDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"icon-art-v2-%@-%@.png", symbol, source ?: @"home"]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return path;
    const NSInteger W = 1280, H = 720;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:W pixelsHigh:H bitsPerSample:8 samplesPerPixel:4
                                                                      hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
    NSColor *bg = t.surface ?: t.background, *acc = t.accent ?: [NSColor whiteColor];
    [[[NSGradient alloc] initWithStartingColor:[bg blendedColorWithFraction:0.25 ofColor:acc] endingColor:bg] drawInRect:NSMakeRect(0, 0, W, H) angle:-60];
    CGFloat cx = W / 2.0, cy = H / 2.0 + 40, r = 170;
    [acc setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx - r, cy - r, 2 * r, 2 * r)] fill];
    NSColor *fg = t.accentText ?: [NSColor whiteColor];
    [fg setStroke]; [fg setFill];
    NSBezierPath *p = [NSBezierPath bezierPath];
    p.lineWidth = 26; p.lineCapStyle = NSRoundLineCapStyle; p.lineJoinStyle = NSRoundLineJoinStyle;
    if ([symbol isEqualToString:@"download"]) {
        [p moveToPoint:NSMakePoint(cx, cy + 95)]; [p lineToPoint:NSMakePoint(cx, cy - 55)];
        [p moveToPoint:NSMakePoint(cx - 70, cy + 15)]; [p lineToPoint:NSMakePoint(cx, cy - 55)]; [p lineToPoint:NSMakePoint(cx + 70, cy + 15)];
        [p moveToPoint:NSMakePoint(cx - 85, cy - 105)]; [p lineToPoint:NSMakePoint(cx + 85, cy - 105)];
        [p stroke];
    } else if ([symbol isEqualToString:@"search"]) {
        [p appendBezierPathWithOvalInRect:NSMakeRect(cx - 95, cy - 45, 140, 140)];
        [p moveToPoint:NSMakePoint(cx + 25, cy - 25)]; [p lineToPoint:NSMakePoint(cx + 90, cy - 90)];
        [p stroke];
    } else if ([symbol isEqualToString:@"grid"]) {
        CGFloat s = 78, g = 22;
        for (int i = 0; i < 4; i++) {
            CGFloat x = cx - s - g / 2 + (i % 2) * (s + g), y = cy - s - g / 2 + (i / 2) * (s + g);
            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, y, s, s) xRadius:14 yRadius:14] fill];
        }
    } else if ([symbol isEqualToString:@"phone"]) {
        p.lineWidth = 20;
        [p appendBezierPathWithRoundedRect:NSMakeRect(cx - 62, cy - 108, 124, 216) xRadius:22 yRadius:22];
        [p stroke];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx - 12, cy - 92, 24, 24)] fill];
    } else if ([symbol isEqualToString:@"history"]) {
        [p appendBezierPathWithOvalInRect:NSMakeRect(cx - 100, cy - 100, 200, 200)];
        [p moveToPoint:NSMakePoint(cx, cy + 62)]; [p lineToPoint:NSMakePoint(cx, cy)]; [p lineToPoint:NSMakePoint(cx + 48, cy - 28)];
        [p stroke];
    } else {   // az
        NSDictionary *a = @{NSFontAttributeName: [NSFont boldSystemFontOfSize:118], NSForegroundColorAttributeName: fg};
        NSAttributedString *s = [[NSAttributedString alloc] initWithString:@"A–Z" attributes:a];
        NSSize sz = s.size;
        [s drawAtPoint:NSMakePoint(cx - sz.width / 2, cy - sz.height / 2)];
    }
    [NSGraphicsContext restoreGraphicsState];
    [[rep representationUsingType:NSPNGFileType properties:@{}] writeToFile:path atomically:YES];
    return path;
}
