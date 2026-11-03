// Persistenz (SQLite): Wiedergabe-Positionen, Gesehen-Status, Verlauf, Einstellungen.
#import "SFModel.h"

@interface SFStore : NSObject
+ (instancetype)shared;
- (NSTimeInterval)positionFor:(NSString *)identifier;
- (double)progressFor:(NSString *)identifier;        // 0..1, 1 = gesehen
- (BOOL)watched:(NSString *)identifier;
- (void)savePosition:(NSTimeInterval)pos duration:(NSTimeInterval)dur forItem:(SFItem *)item;
- (void)setWatched:(BOOL)w forItem:(SFItem *)item;
- (void)flush;   // ausstehende Schreibvorgänge abschließen (Beenden)
- (NSArray *)continueWatching:(NSInteger)limit source:(NSString *)source;  // SFItem
- (NSArray *)recentlyPlayed:(NSInteger)limit source:(NSString *)source;
- (void)removeFromContinue:(NSString *)identifier;
- (NSString *)setting:(NSString *)key;
- (void)setSetting:(NSString *)value forKey:(NSString *)key;
// Einfacher JSON-Cache für Provider (z.B. Mediathek-Antworten), mit Alter.
- (id)cachedJSON:(NSString *)key maxAge:(NSTimeInterval)age;
- (void)cacheJSON:(id)obj forKey:(NSString *)key;
// Generischer Zugriff für andere Module (Downloads). Werte: NSString/NSNumber/NSData/NSNull.
- (void)run:(NSString *)sql args:(NSArray *)args;                // asynchron (Schreiben)
- (NSArray *)rows:(NSString *)sql args:(NSArray *)args;          // synchron, Array von Dictionaries
// Fortschritt/Verlauf auf neue ID umschlüsseln (Migration local:… -> yt:…); nur wenn Ziel frei
- (BOOL)moveProgress:(NSString *)from toItem:(SFItem *)item;   // Migration: id + Item ersetzen
@end
