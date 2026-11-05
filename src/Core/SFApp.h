// The app contract (docs/architecture.md): everything source-specific (YouTube, ZDF, ARD, ORF,
// media.ccc.de, …) lives in one class per app under src/Apps/<App>/ conforming to SFApp.
// The core never asks "which app is this?" by string; it asks SFAppRegistry for the app that owns
// an identifier, a ref namespace ("zdfshow:…") or an item, and calls the protocol.
//
// Apps are stateless from the core's point of view (class methods); app-internal services keep
// their own singletons. Optional methods = optional capabilities: absent means the feature is
// hidden for this app (no stubs).
#import "SFModel.h"
#import "SFTheme.h"

@class SFNavigator;

// Download source of an item (video URL, optional separate audio URL)
typedef void (^SFDownloadURLDone)(NSURL *url, NSURL *audio, NSError *e);
// Online state for "Platz schaffen": 1 online, 0 gone, -1 unknown (network/server trouble)
typedef void (^SFAvailabilityDone)(NSInteger online);

@protocol SFApp <NSObject>
// --- identity ---
+ (NSString *)appIdentifier;     // "zdf": SFItem.source, theme name, logo file res/logos/<id>.png
+ (NSString *)appName;           // "ZDF"
+ (NSString *)appSummary;        // home tile text: "Mediathek, Sendungen und Live-TV"
+ (NSArray *)refPrefixes;        // namespaces of resolver refs / identifiers it owns ("zdf", "zdfshow")
+ (void)configureTheme:(SFTheme *)theme;   // tokens on top of the base theme (colors, fonts, logo, …)
+ (NSColor *)homeTileColor;      // app tile background on the home screen
+ (NSInteger)homeTileLogoVariant;// 0 original, 1 light text, 2 white
// --- start page: the app's own shelves; the shell frames them (continue watching, watch later,
//     downloads, search tile) ---
+ (SFPageLoader)homeLoader;

@optional
+ (NSString *)searchPlaceholder;   // keyboard hint ("Vorträge suchen"); default "Sendungen und Videos suchen"
+ (NSArray *)showRefPrefixes;      // namespaces that are shows/channels: followable, have a page + feed
+ (BOOL)homeIncludesFollows;       // YES: homeLoader shows followed shows/new episodes itself (else the shell adds them)
// --- lifecycle ---
+ (void)start;                   // launch (services, warm-up); called once, in registry order
+ (void)stop;                    // quit (best effort, short)
// --- search ---
+ (SFPageLoader)searchLoader:(NSString *)query;
+ (void)suggestions:(NSString *)prefix done:(void (^)(NSArray *list))done;   // done on main, never nil
// --- playback: ref = full "prefix:id" of one of refPrefixes ---
+ (void)resolve:(NSString *)ref done:(SFURLDone)done;
+ (void)resolveOnline:(NSString *)ref done:(SFURLDone)done;   // skip local copies ("Online abspielen")
// --- shows / channels ---
+ (SFPageLoader)showPageLoader:(NSString *)ref title:(NSString *)title;   // page of a show/channel ref
+ (void)showRefForItem:(SFItem *)item done:(void (^)(NSString *ref))done; // item -> its show/channel ref
+ (void)feed:(NSString *)ref done:(void (^)(NSArray *items, NSError *e))done;   // newest episodes of a show ref
// --- library ---
+ (void)downloadSourceForItem:(SFItem *)item done:(SFDownloadURLDone)done;
+ (NSTimeInterval)downloadsPausedUntil;   // e.g. bot check: no downloads until then (epoch s, 0 = no pause)
+ (void)availabilityOfItem:(SFItem *)item done:(SFAvailabilityDone)done;
// --- items ---
+ (SFItem *)itemForIdentifier:(NSString *)identifier;   // placeholder item for an id of this app (phone, end screens)
+ (NSString *)focusPreloadRefForItem:(SFItem *)item;    // start resolving early when a tile gets focus
+ (void)preloadOnFocus:(SFItem *)item;
// --- dev (sofa-dev FIFO): app-specific commands, YES = handled ---
+ (BOOL)handleDevCommand:(NSString *)cmd arg:(NSString *)arg;
@end

@interface SFAppRegistry : NSObject
+ (BOOL)isShowRef:(NSString *)ref;         // in a showRefPrefixes namespace of its app
+ (void)registerApp:(Class)app;            // order = home tile order
+ (NSArray *)apps;                         // Classes conforming to SFApp
+ (Class)appNamed:(NSString *)identifier;  // by appIdentifier
+ (Class)appForRef:(NSString *)ref;        // by the namespace before ':'
+ (Class)appForItem:(SFItem *)item;        // by item.source, else by its ref/identifier namespace
+ (void)startAll;
+ (void)stopAll;
@end

// "prefix:id" helpers
NSString *SFRefPrefix(NSString *ref);   // nil without ':'
NSString *SFRefID(NSString *ref);       // part after the first ':' (whole string without ':')
