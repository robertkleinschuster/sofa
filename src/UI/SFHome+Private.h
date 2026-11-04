// SFHome – privater Teil: gemeinsame Hilfen für SFHome.m (Home, Verlauf, App-Startseiten),
// SFHome+Downloads.m (Downloads-Seite) und SFHome+Settings.m (Einstellungen, Handy-Kachel).
#import "SFHome.h"
#import "SFLibrary.h"

@interface SFHome ()
+ (SFItem *)showTile:(SFShow *)sh;   // Kachel einer lokalen Sendung (öffnet showLoader:source:)
@end
