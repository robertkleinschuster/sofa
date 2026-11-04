// Einmalige Übernahme der alten ytdl-sub/Kodi-Bibliothek (~/TV Shows) in die Offline-Schicht:
// Videos werden in den Sofa-Speicher VERSCHOBEN (gleiches Volume = nur umbenennen, kein Platzbedarf),
// Identität = Quell-ID (yt:/zdf:/ard:), Fortschritt wandert mit, Abos aus subscriptions-kodi.yaml.
// Danach landet der Rest von ~/TV Shows (NFOs, leere Ordner) im Papierkorb.
// Dev: nur mit SOFA_MIGRATE_ROOT (Testkopie), Fortschritt wird dort nicht angefasst.
#import "SFCore.h"

void SFMigrateLibraryIfNeeded(void);
