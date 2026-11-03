// „Später ansehen“: eigene, gemeinsame Merkliste von Sofa – für Videos aus allen Apps.
// Wie beim Folgen gilt: Sofa ist die Quelle, die Liste des YouTube-Kontos wird nur einmalig
// übernommen. Hinzufügen/Entfernen über OK halten auf einem Video. Gesehene Videos fallen
// von selbst heraus (wie „Gesehene entfernen“ bei YouTube, nur automatisch).
#import "SFModel.h"

@interface SFWatchLater : NSObject
+ (instancetype)shared;
- (BOOL)contains:(NSString *)identifier;
- (void)add:(SFItem *)item;
- (void)remove:(NSString *)identifier;
- (NSArray *)items:(NSString *)source;                          // neueste zuerst, nil = alle Apps
- (void)importItems:(NSArray *)items once:(NSString *)key;      // einmalige Übernahme (YouTube-Konto)
@end

// Startseiten-Loader einer App um das Regal „Später ansehen“ ergänzen (nach „Weiterschauen“)
SFPageLoader SFWithWatchLater(SFPageLoader loader, NSString *source);
