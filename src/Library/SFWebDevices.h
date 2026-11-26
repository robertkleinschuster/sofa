// SFWebDevices - the browsers paired with Sofa im Browser (docs/pwa.md). A device pairs with the code
// the TV shows (Einstellungen -> Sofa im Browser) and gets a random token; Sofa keeps only its
// SHA-256 (table web_devices). A code exists only while the TV shows it, lives 5 minutes and is
// replaced after three wrong entries; wrong entries are limited globally too.
#import "SFModel.h"

extern NSString *const SFWebDevicesDidChangeNotification;   // devices or the code changed (main thread)

// What a device paired with (docs/api.md "Pairing"): the PWA or a native app, as it said at pairing.
@interface SFWebClient : NSObject
@property (nonatomic, readonly, copy) NSString *kind;       // web | ios | android
@property (nonatomic, readonly, copy) NSString *app;        // the app's name as it gave it; nil = not said
@property (nonatomic, readonly, copy) NSString *version;    // its version; nil = not said
// From a pairing's `client` ({kind, app?, version?}): absent = the PWA before it said so (web); nil =
// not a client Sofa knows (an unknown kind, values that are no short strings)
+ (instancetype)clientFrom:(id)json;
+ (instancetype)kind:(NSString *)kind app:(NSString *)app version:(NSString *)version;   // as stored
@property (nonatomic, readonly, copy) NSString *label;      // for the TV (German): "Browser", "iOS-App 1.2", "Android-App"
@end

@interface SFWebDevice : NSObject
@property (nonatomic, copy) NSString *identifier, *name;
@property (nonatomic, strong) SFWebClient *client;
@property (nonatomic) NSTimeInterval paired, seen;   // epoch s; seen 0 = never since pairing
@end

@interface SFWebDevices : NSObject
+ (instancetype)shared;
- (NSArray *)devices;                 // SFWebDevice, the most recently paired first. Any thread.
// Pairing window (main thread): open shows a code (and renews it when it expires), close ends it.
- (void)openPairing;
- (void)closePairing;
@property (nonatomic, readonly, copy) NSString *pairingCode;   // nil = no pairing open
@property (nonatomic, readonly, strong) NSDate *pairingCodeExpires;
// Any thread. On success @{token, device, name}; else nil with *status: 403 wrong code, 410 no pairing
// open, 429 too many wrong entries, 500 no randomness.
- (NSDictionary *)pairWithCode:(NSString *)code name:(NSString *)name client:(SFWebClient *)client status:(NSInteger *)status;
- (NSString *)deviceForToken:(NSString *)token;   // its id, nil = unknown; notes it as seen. Any thread.
- (void)remove:(NSString *)identifier;
- (void)removeAll;
@end
