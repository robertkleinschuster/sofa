// HTTP/JSON for all online sources: NSURLSession, timeout, optional SQLite cache.
#import "SFCore.h"

typedef void (^SFJSONDone)(id json, NSError *error);   // main thread

// Network status (SystemConfiguration reachability; dev: SOFA_OFFLINE=1 simulates offline)
extern NSString *const SFNetOnlineDidChangeNotification;

// Session delegate without TLS certificate verification (user decision 2026-11-04: Sofa only loads data
// unverified; code – app updates, yt-dlp – is signed separately). For every NSURLSession of the app.
id<NSURLSessionDelegate> SFTrustAllSessionDelegate(void);

@interface SFNet : NSObject
+ (BOOL)isOnline;
+ (void)startMonitoring;
+ (void)getJSON:(NSString *)url headers:(NSDictionary *)headers cacheAge:(NSTimeInterval)age done:(SFJSONDone)done;
+ (void)postJSON:(NSString *)url body:(id)body headers:(NSDictionary *)headers cacheAge:(NSTimeInterval)age done:(SFJSONDone)done;
+ (NSString *)userAgent;
// Percent-encoding for path/query parts (everything except A-Z a-z 0-9 - . _ ~)
+ (NSString *)escape:(NSString *)s;
// Geo check (e.g. ARD regionCheckUrl): YES if the URL returns the expected text.
// Result cached per URL for 1 h.
+ (void)checkRegion:(NSString *)url expect:(NSString *)expect done:(void (^)(BOOL allowed))done;
@end
