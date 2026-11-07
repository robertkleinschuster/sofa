// sources: src/Framework/SFLabel.m
// SFLabel looks (hero text off the main thread, 2026-11-07): a look drawn on the text queue is the
// same picture the label draws itself, applying it shows that picture without drawing again, and
// any later change to the label draws anew.
#import "SFCore.h"
#import "SFLayers.h"

BOOL SFDevMode = NO;   // main.m's, for SFCore.m
static int fails = 0;
#define CHECK(c, msg) do { if (!(c)) { fprintf(stderr, "FAIL %s (%s:%d)\n", msg, __FILE__, __LINE__); fails++; } } while (0)

static NSData *pixels(id contents) {
    CGImageRef img = (__bridge CGImageRef)contents;
    if (!img) return nil;
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    NSMutableData *d = [NSMutableData dataWithLength:w * h * 4];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(d.mutableBytes, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);
    CGContextDrawImage(c, CGRectMake(0, 0, w, h), img);
    CGContextRelease(c);
    return d;
}

static SFLabel *makeLabel(void) {
    SFLabel *l = [SFLabel labelWithFont:[NSFont boldSystemFontOfSize:40] color:[NSColor whiteColor]];
    l.maxLines = 2; l.shadow = YES; l.contentsScale = 1;
    return l;
}

int main(void) {
    @autoreleasepool {
        NSString *text = @"Ein langer Titel mit Umlauten äöü und Emoji \U0001F525\U0001F30A, der auf zwei Zeilen umbricht und dann abgeschnitten wird";
        SFLabel *sync = makeLabel();
        sync.text = text;
        [sync sizeToFitWidth:500];
        [sync display];
        NSData *want = pixels(sync.contents);
        CHECK(want.length > 0, "the label draws itself");

        SFLabel *async = makeLabel();
        SFLabelLook *look = [async lookForText:text maxLines:2 width:500];
        CHECK(CGSizeEqualToSize(look.size, sync.bounds.size), "a look measures like sizeToFitWidth:");
        __block BOOL done = NO;
        [SFLabelLook render:@[look] done:^{ done = YES; }];
        NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:10];
        while (!done && [limit timeIntervalSinceNow] > 0) [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        CHECK(done, "render: calls back on the main thread");

        [async applyLook:look];
        CHECK([async.text isEqualToString:text] && async.maxLines == 2, "applyLook: sets text and lines");
        CHECK(CGSizeEqualToSize(async.bounds.size, look.size), "applyLook: sets the size");
        [async display];
        id shown = async.contents;
        CHECK([pixels(shown) isEqualToData:want], "drawn off the main thread = drawn by the label");
        [async display];
        CHECK(async.contents == shown, "an applied look is shown, not drawn again");

        async.color = [NSColor redColor];
        [async display];
        CHECK(async.contents != shown && ![pixels(async.contents) isEqualToData:want], "a later change draws anew");
    }
    if (fails) { fprintf(stderr, "%d failure(s)\n", fails); return 1; }
    printf("labellook ok\n");
    return 0;
}
