// One-time import of the old ytdl-sub/Kodi library (~/TV Shows) into the offline layer:
// videos are MOVED into Sofa's storage (same volume = just a rename, no extra space),
// identity = source ID (yt:/zdf:/ard:), progress moves along, subscriptions from subscriptions-kodi.yaml.
// Afterwards the rest of ~/TV Shows (NFOs, empty folders) goes to the trash.
// Dev: only with SOFA_MIGRATE_ROOT (test copy), progress is not touched there.
#import "SFCore.h"

void SFMigrateLibraryIfNeeded(void);
