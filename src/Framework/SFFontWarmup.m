#import "SFFontWarmup.h"
#import <CoreText/CoreText.h>
#import "SFCore.h"

void SFWarmFonts(NSArray *texts, NSArray *fonts, dispatch_block_t done) {
    SFBackground(^{
        @autoreleasepool {
            for (NSString *s in texts)
                for (NSFont *f in fonts) {   // (NSFont and CTFontRef are toll-free bridged)
                    NSAttributedString *a = [[NSAttributedString alloc] initWithString:s attributes:@{(__bridge id)kCTFontAttributeName: f}];
                    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)a);
                    if (line) { CTLineGetTypographicBounds(line, NULL, NULL, NULL); CFRelease(line); }
                }
        }
        SFMain(done);
    });
}
