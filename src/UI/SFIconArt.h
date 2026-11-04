// Kachelbilder für Sofa-eigene Einstiege (Suche, A–Z, Kategorien, Downloads, Handy, Verlauf):
// Symbol in einem Kreis in den Farben der jeweiligen App, einmal gerendert und als PNG gecacht.
// Damit gibt es keine großen leeren Flächen, wo die Quelle selbst kein Bild liefert.
#import "SFCore.h"

// symbol: download | search | az | grid | phone | history
NSString *SFIconArt(NSString *symbol, NSString *source);
