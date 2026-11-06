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
#import "SFPlayerHost.h"
#import "SFHomeSection.h"
#import "SFHomeFeatures.h"

@class SFNavigator;

// Download source of an item (video URL, optional separate audio URL). info: what the source knows
// better than the list the item came from - "published" (NSDate, exact publication time; list
// pages may only have "vor 2 Wochen"). nil = nothing to add.
typedef void (^SFDownloadURLDone)(NSURL *url, NSURL *audio, NSDictionary *info, NSError *e);
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
+ (BOOL)showsAreChannels;          // YES: shows are "Kanäle" with "Videos" (YouTube), else "Sendungen" with "Folgen"
+ (NSArray *)homeSections;         // SFHomeSection contributions to Sofa's home page (priority >= SFHomePriorityApp)
// Content for the shared home rows (SFHomeFeatures.h: SFHomeTopicLive, SFHomeTopicHighlights …),
// merged with the other apps'. done once, any thread: topic -> SFItems in the app's own order of
// importance. nil or a missing topic = no answer this time (request failed): what the app featured
// before stays; an empty list = nothing to feature now. Set drm / geoRegion from the raw data - Home
// leaves out what can't play here. Called at launch and every 30 min - use the source's cheap,
// cached start page data, never one request per item.
+ (void)homeFeatures:(void (^)(NSDictionary *itemsByTopic))done;
// --- lifecycle ---
+ (void)start;                   // launch (services, warm-up); called once, in registry order
// --- search ---
+ (SFPageLoader)searchLoader:(NSString *)query;
+ (void)suggestions:(NSString *)prefix done:(void (^)(NSArray *list))done;   // done on main, never nil
// --- playback: ref = full "prefix:id" of one of refPrefixes ---
+ (void)resolve:(NSString *)ref done:(SFURLDone)done;
+ (void)resolveOnline:(NSString *)ref done:(SFURLDone)done;   // skip local copies ("Online abspielen")
// --- player hooks: app knowledge about a running playback. `source` = the stream description the
//     app's resolver attached to the opened URL (SFMPVSourceFor). ---
+ (BOOL)playbackIsSession:(NSDictionary *)source;   // stream served by an app session (local service) whose loss needs recovery
+ (void)playbackSessionFailed:(NSDictionary *)source item:(SFItem *)item reason:(NSString *)why;   // before the player reopens the item (recover the app's side, e.g. a fresh session)
+ (NSString *)playbackSessionLostNotification;      // posted when the service behind session streams died
+ (BOOL)playbackLiveEnded:(NSDictionary *)source done:(void (^)(BOOL ended))done;   // session live playlist ended: broadcast over or lost? NO = not a live session stream (done not called)
+ (void)upNextForItem:(SFItem *)item done:(void (^)(SFItem *next))done;   // autoplay recommendation (from half time)
// info panel: description/channel and related videos (done on main; related empty + details nil =
// failed). details keys: description, channel, showRef, avatar, date (NSDate) - only when found.
+ (void)watchDetailsForItem:(SFItem *)item done:(void (^)(NSArray *related, NSDictionary *details))done;
// End cards (creator tiles over the last seconds, SFPlayerScreen+Endscreen.m) come in the stream
// description under "endCards": [{kind: video|playlist|channel|follow, ref ("yt:…", "ytplaylist:…",
// "ytchannel:…"), firstRef (playlist: the linked video), title, image, left, top, width,
// aspectRatio (fractions of the picture), startMs, endMs}] - the app converts its own data.
// --- shows / channels ---
+ (SFPageLoader)showPageLoader:(NSString *)ref title:(NSString *)title;   // page of a show/channel ref
+ (void)showRefForItem:(SFItem *)item done:(void (^)(NSString *ref))done; // item -> its show/channel ref
+ (void)feed:(NSString *)ref done:(void (^)(NSArray *items, NSError *e))done;   // newest episodes of a show ref
+ (void)showImage:(NSString *)ref done:(void (^)(NSString *url))done;   // a followed show's picture when its stored one is missing/gone; done on main, nil = none (now)
// --- library ---
+ (void)downloadSourceForItem:(SFItem *)item done:(SFDownloadURLDone)done;
+ (NSTimeInterval)backgroundPausedUntil;   // e.g. bot check: no background requests (feed refreshes, downloads) until then (epoch s, 0 = no pause)
+ (void)availabilityOfItem:(SFItem *)item done:(SFAvailabilityDone)done;
// --- items ---
+ (SFItem *)itemForRef:(NSString *)ref title:(NSString *)title image:(NSString *)image;   // playable item for a video ref (phone, end cards); local copy preferred
+ (void)updateStoredItem:(SFItem *)item;   // read back from storage (history, continue watching): refresh derived fields, e.g. picture URLs; a local picture stays
+ (SFPageLoader)listLoader:(NSString *)ref title:(NSString *)title;   // a playable list (playlist): first shelf = the videos in order
+ (void)preloadOnFocus:(SFItem *)item;   // focus rests on a (not downloaded) video while online: start resolving early
// --- remote control: a phone app as remote (YouTube "Mit TV verbinden"). The app owns pairing,
//     protocol and its settings; the shell starts it with a host and shows its status. ---
+ (void)startRemoteWithHost:(id<SFPlayerHost>)host;
+ (void)stopRemote;                      // quit: tell the phones (best effort, short)
+ (NSString *)remoteStatus:(BOOL *)paused;   // header pill ("Handy: Pixel"), nil = nothing connected
+ (NSString *)remoteStatusNotification;      // posted when remoteStatus changes
// --- dev (sofa-dev FIFO): app-specific commands, YES = handled. Apps see every command first. ---
+ (BOOL)handleDevCommand:(NSString *)cmd arg:(NSString *)arg host:(id<SFPlayerHost>)host;
// --- tests: what the app's pure parser makes of a recorded answer of `kind`, as lines
//     ("item " + SFCanonicalItem, ...); nil = unknown kind. tools/test-parse, tests/fixtures/<app>/<kind>-<name>.json.gz ---
+ (NSArray *)parseFixture:(id)json kind:(NSString *)kind;
@end

@interface SFAppRegistry : NSObject
+ (BOOL)isShowRef:(NSString *)ref;         // in a showRefPrefixes namespace of its app
+ (void)registerApp:(Class)app;            // order = home tile order
+ (NSArray *)apps;                         // Classes conforming to SFApp
+ (Class)appNamed:(NSString *)identifier;  // by appIdentifier
+ (Class)appForRef:(NSString *)ref;        // by the namespace before ':'
+ (Class)appForItem:(SFItem *)item;        // by item.source, else by its ref/identifier namespace
+ (void)startAll;
// remote control services of all apps
+ (void)startRemotesWithHost:(id<SFPlayerHost>)host;
+ (void)stopRemotes;
+ (NSArray *)remoteStatusNotifications;
// status pill for a page in theme `themeID`: on pages of no app (home) every remote, in an app only its own
+ (NSString *)remoteStatusForTheme:(NSString *)themeID paused:(BOOL *)paused;
+ (BOOL)handleDevCommand:(NSString *)cmd arg:(NSString *)arg host:(id<SFPlayerHost>)host;
@end

// Wording for a show ref / item: YES = channel ("Kanal", "Videos")
BOOL SFShowRefIsChannel(NSString *ref);
BOOL SFItemShowsAreChannels(SFItem *item);
BOOL SFSourceShowsAreChannels(NSString *source);   // by app identifier
NSTimeInterval SFBackgroundPausedUntil(NSString *ref);   // the owning app's backgroundPausedUntil (0 = go)

// "prefix:id" helpers
NSString *SFRefPrefix(NSString *ref);   // nil without ':'
NSString *SFRefID(NSString *ref);       // part after the first ':' (whole string without ':')
