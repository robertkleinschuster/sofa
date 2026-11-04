// Tile images for Sofa's own entries (search, A–Z, categories, downloads, phone, history):
// a symbol in a circle in the colours of the respective app, rendered once and cached as PNG.
// So there are no large empty areas where the source itself delivers no image.
#import "SFCore.h"

// symbol: download | search | az | grid | phone | history
NSString *SFIconArt(NSString *symbol, NSString *source);
