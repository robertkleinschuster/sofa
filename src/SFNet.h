// HTTP/JSON für alle Online-Quellen: NSURLSession, Timeout, optionaler SQLite-Cache.
#import "SFCore.h"

typedef void (^SFJSONDone)(id json, NSError *error);   // Main-Thread

@interface SFNet : NSObject
+ (void)getJSON:(NSString *)url headers:(NSDictionary *)headers cacheAge:(NSTimeInterval)age done:(SFJSONDone)done;
+ (void)postJSON:(NSString *)url body:(id)body headers:(NSDictionary *)headers cacheAge:(NSTimeInterval)age done:(SFJSONDone)done;
+ (NSString *)userAgent;
// Geo-Prüfung (z.B. ARD regionCheckUrl): YES wenn die URL den erwarteten Text liefert.
// Ergebnis pro URL 1 h gecacht.
+ (void)checkRegion:(NSString *)url expect:(NSString *)expect done:(void (^)(BOOL allowed))done;
@end
