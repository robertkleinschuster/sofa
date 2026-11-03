// Offizielle Logos (res/logos/*.png, Wikimedia-Renderings, Home-Use) in Varianten.
#import "SFCore.h"

typedef NS_ENUM(NSInteger, SFLogoVariant) {
    SFLogoOriginal,     // wie geliefert (weißer Hintergrund wird freigestellt)
    SFLogoLightText,    // dunkle Pixel -> weiß (für dunkle Flächen, Farbanteile bleiben)
    SFLogoWhite,        // komplett weiß (einfarbige Logos auf Markenfarbe)
};

CGImageRef SFLogoImage(NSString *name, SFLogoVariant variant);   // gecacht, nicht freigeben
