// SFWarmFonts - loads the fonts a set of texts will need, off the main thread. Fonts load on first
// use; the cold path (font files, a symbol's fallback font, the font server under disk load)
// blocked the main thread up to 1 s when the end screen was built (hitch 2026-11-08). Laying every
// text out once in each font on a queue loads them; `done` runs on the main thread afterwards.
// CoreText (thread-safe), not NSString drawing (thread-safe only from 10.11).
#import <AppKit/AppKit.h>

void SFWarmFonts(NSArray *texts, NSArray *fonts, dispatch_block_t done);
