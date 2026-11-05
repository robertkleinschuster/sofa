// "Später ansehen" (watch later): Sofa's own shared list – for videos from all apps.
// As with follows: Sofa is the source, the YouTube account's list is only imported once.
// Add/remove by holding OK on a video. Watched videos drop out on their own
// (like "Gesehene entfernen" on YouTube, just automatic).
#import "SFModel.h"

@interface SFWatchLater : NSObject
+ (instancetype)shared;
- (BOOL)contains:(NSString *)identifier;
- (void)add:(SFItem *)item;
- (void)remove:(NSString *)identifier;
- (NSArray *)items:(NSString *)source;                          // newest first, nil = all apps
@end

// add the shelf "Später ansehen" to an app's start page loader (after "Weiterschauen")
SFPageLoader SFWithWatchLater(SFPageLoader loader, NSString *source);
