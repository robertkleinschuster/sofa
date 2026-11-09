// Official logos (res/logos/*.png, Wikimedia renderings, home use) in variants.
#import "SFCore.h"

typedef NS_ENUM(NSInteger, SFLogoVariant) {
    SFLogoOriginal,     // as delivered (white background is cut out)
    SFLogoLightText,    // dark pixels -> white (for dark surfaces, colour parts stay)
    SFLogoWhite,        // fully white (single-colour logos on the brand colour)
};

CGImageRef SFLogoImage(NSString *name, SFLogoVariant variant);   // cached, do not release; any thread
// The square mark of a brand (res/logos/marks/<name>.png: an app's symbol, a station's logo) for a
// round avatar; NULL when there is none. Cached, do not release; any thread.
CGImageRef SFLogoMark(NSString *name);
void SFLogoPrepare(void);   // renders all of them in the background (at launch)
