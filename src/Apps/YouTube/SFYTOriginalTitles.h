// SFYTOriginalTitles - every video under the uploader's own title. YouTube translates titles into the
// viewer's language in every list and on the watch page (2026-11-25: English videos under German
// titles); only oEmbed keeps the original - what browser add-ons against the translation ask too.
// Asked once per video through the engine (one client), one call at a time at a calm pace, paused
// while the breaker holds (bot check); the answer is stored for good (SFStore original titles, which
// also rewrites the stored item) and every list shows it from then on.
#import <Foundation/Foundation.h>

@interface SFYTOriginalTitles : NSObject
+ (void)start;                         // after launch: the stored videos not yet known, slowly
+ (void)want:(NSString *)videoID;      // shown now (a list, a feed): ahead of the stored ones
+ (void)wantItems:(NSArray *)items;    // SFItem: every YouTube video without a known title
@end
