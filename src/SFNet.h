// HTTP/JSON für alle Online-Quellen: NSURLSession, Timeout, optionaler SQLite-Cache.
#import "SFCore.h"

typedef void (^SFJSONDone)(id json, NSError *error);   // Main-Thread

// Netzstatus (SystemConfiguration-Reachability; Dev: SOFA_OFFLINE=1 simuliert offline)
extern NSString *const SFNetOnlineDidChangeNotification;

@interface SFNet : NSObject
+ (BOOL)isOnline;
+ (void)startMonitoring;
+ (void)getJSON:(NSString *)url headers:(NSDictionary *)headers cacheAge:(NSTimeInterval)age done:(SFJSONDone)done;
+ (void)postJSON:(NSString *)url body:(id)body headers:(NSDictionary *)headers cacheAge:(NSTimeInterval)age done:(SFJSONDone)done;
+ (NSString *)userAgent;
// Prozent-Kodierung für Pfad-/Query-Teile (alles außer A-Z a-z 0-9 - . _ ~)
+ (NSString *)escape:(NSString *)s;
// Geo-Prüfung (z.B. ARD regionCheckUrl): YES wenn die URL den erwarteten Text liefert.
// Ergebnis pro URL 1 h gecacht.
+ (void)checkRegion:(NSString *)url expect:(NSString *)expect done:(void (^)(BOOL allowed))done;
@end
