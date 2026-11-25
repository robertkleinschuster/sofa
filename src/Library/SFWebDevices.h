// SFWebDevices - the browsers paired with Sofa im Browser (docs/pwa.md). A device pairs with the code
// the TV shows (Einstellungen -> Sofa im Browser) and gets a random token; Sofa keeps only its
// SHA-256 (table web_devices). A code exists only while the TV shows it, lives 5 minutes and is
// replaced after three wrong entries; wrong entries are limited globally too.
#import "SFModel.h"

extern NSString *const SFWebDevicesDidChangeNotification;   // devices or the code changed (main thread)

@interface SFWebDevice : NSObject
@property (nonatomic, copy) NSString *identifier, *name;
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
// Any thread. On success @{token, device}; else nil with *status: 403 wrong code, 410 no pairing open,
// 429 too many wrong entries.
- (NSDictionary *)pairWithCode:(NSString *)code name:(NSString *)name status:(NSInteger *)status;
- (NSString *)deviceForToken:(NSString *)token;   // its id, nil = unknown; notes it as seen. Any thread.
- (void)remove:(NSString *)identifier;
- (void)removeAll;
@end
