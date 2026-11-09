// Unified data model of all sources: item (video, folder, live, action),
// shelf (row/grid of items) and page (a screen full of shelves).
#import "SFCore.h"
#import "SFTheme.h"

// YouTube background picture in TV resolution (1280x720). Not every video has it (404 for
// low-resolution uploads) - SFImageLayer then falls back to the tile image (fallbackSource).

typedef NS_ENUM(NSInteger, SFItemKind) {
    SFItemVideo,     // playable
    SFItemLive,      // live stream (no resume position)
    SFItemFolder,    // opens a page (show, channel, category)
    SFItemAction,    // runs a block (launch app, setting, ...)
};

typedef NS_ENUM(NSInteger, SFShelfLayout) {
    SFShelfRail,     // horizontal row
    SFShelfGrid,     // wrapping grid
};

@class SFPage, SFItem, SFBroadcast;

// One programme on a live channel (source EPG): shown on live tiles ("Brisant · bis 18:00", progress)
// and in the hero ("17:15 – 18:00 · Danach: Tagesschau", its description).
@interface SFBroadcast : NSObject
@property (nonatomic, copy) NSString *title, *subtitle, *plot;
@property (nonatomic, strong) NSDate *start, *end;
+ (instancetype)title:(NSString *)title start:(NSDate *)start end:(NSDate *)end;
- (double)progressAt:(NSDate *)date;   // 0…1
- (NSDictionary *)dictionaryRepresentation;
+ (instancetype)broadcastWithDictionary:(NSDictionary *)d;
@end
typedef void (^SFPageDone)(SFPage *page, NSError *error);
typedef void (^SFPageLoader)(SFPageDone done);
typedef void (^SFURLDone)(NSURL *url, NSError *error);
typedef void (^SFResolver)(SFURLDone done);

@interface SFItem : NSObject <NSCopying>
@property (nonatomic) SFItemKind kind;
@property (nonatomic, copy) NSString *identifier;      // stable, for resume/history
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;        // e.g. channel · date
@property (nonatomic, copy) NSString *plot;
@property (nonatomic, copy) NSString *image;           // path or URL
@property (nonatomic, copy) NSString *backdrop;        // large background image
@property (nonatomic, copy) NSString *channel;         // show / channel
@property (nonatomic, copy) NSString *channelImage;    // the channel's avatar (URL or file), where the source names one; nil = none
@property (nonatomic, copy) NSString *source;          // theme ID of the origin
@property (nonatomic, copy) NSString *badge;           // "LIVE", "NEU", "UT", ...
@property (nonatomic) BOOL drm;                        // copy-protected: not playable on 10.9 (no "Abspielen", selecting → notice)
@property (nonatomic, copy) NSString *geoRegion;       // ISO country the stream is limited to (raw source data), nil = everywhere; see SFNet regionAllowed:
@property (nonatomic, strong) NSDate *date;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic) SFTileStyle style;
@property (nonatomic, strong) NSURL *playURL;
@property (nonatomic, copy) SFResolver resolver;       // if the URL must be determined first
@property (nonatomic, copy) NSString *resolverRef;     // "provider:ref" (persistable)
@property (nonatomic, copy) SFPageLoader pageLoader;   // for folders
@property (nonatomic, copy) dispatch_block_t action;   // for actions
@property (nonatomic, strong) NSColor *tint;           // tile colour (app tiles)
@property (nonatomic, copy) NSString *themeName;       // theme of the opened page
@property (nonatomic, copy) NSString *localPath;       // downloaded file
@property (nonatomic) BOOL streamOnly;                 // play online even if a download exists ("Online abspielen"); not saved
@property (nonatomic) BOOL inDownloadsList;            // tile on the Downloads page (no "Offline" chip needed there); not saved
@property (nonatomic, copy) NSString *playlistID;      // opened from a playlist: "Als Nächstes" = next video of the playlist
@property (nonatomic, copy) NSString *heroTitle;       // hero title instead of title (e.g. channel name above an action tile)
@property (nonatomic, copy) NSString *heroMeta;        // hero meta line instead of channel/date/duration
@property (nonatomic, copy) NSString *externalID;      // ID at the source (YouTube video ID)
@property (nonatomic, copy) NSString *showRef;         // show/channel of the episode ("ytchannel:UC…", "zdfshow:…") → "Zur Sendung"
@property (nonatomic) BOOL imageFit;                   // fit the image instead of filling (logos)
@property (nonatomic, copy) NSString *logo;            // res/logos/<name>.png (app tiles)
@property (nonatomic) BOOL showsSourceMark;            // rows mixed from several apps: without a channel/station avatar the tile's avatar is its app's symbol; not copied - belongs to that row only
@property (nonatomic) NSInteger logoVariant;           // SFLogoVariant
@property (nonatomic) long long viewCount;             // views at the source (raw count, e.g. YouTube RSS media:statistics); 0 = unknown
@property (nonatomic, copy) NSString *station;         // live: the TV channel itself ("3sat", "phoenix"), from the source's ids - the same channel offered by two apps
@property (nonatomic, copy) NSArray *schedule;         // live: the channel's programme (SFBroadcast, by time) from the source's EPG
- (SFBroadcast *)broadcastAt:(NSDate *)date;           // what runs on this live channel then (nil = no schedule / gap)
- (SFBroadcast *)broadcastAfter:(SFBroadcast *)b;      // the next one ("Danach")

- (NSDictionary *)dictionaryRepresentation;
+ (instancetype)itemWithDictionary:(NSDictionary *)d;
- (void)resolveURL:(SFURLDone)done;    // playURL or resolver or provider registry
@end

// One line per item for parser golden tests (tools/test-parse): every stored field, keys sorted, the
// whole schedule. Dates: as age in hours when the source gives relative dates ("vor 2 Tagen" -
// the age is what stays stable between runs), else as ISO 8601 UTC with the date label in the
// subtitle as "<date>".
NSString *SFCanonicalItem(SFItem *item, BOOL datesAsAge);

extern NSString *const SFDRMNotice;   // uniform notice text for DRM content

@interface SFShelf : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic) SFShelfLayout layout;
@property (nonatomic) SFTileStyle style;
@property (nonatomic, copy) NSArray *items;
@property (nonatomic) NSUInteger focusIndex;       // rail: initially focused entry (e.g. the running video of a playlist)
// The shelf's further items, loaded when the viewer nears its end (a rail's last tiles, a grid's last
// lines) - at a person's pace, one portion per approach, appended without moving what is shown.
// done (main): the next items and whether more follow. nil = the shelf is complete.
@property (nonatomic, copy) void (^moreLoader)(void (^done)(NSArray *items, BOOL more));
+ (instancetype)shelf:(NSString *)title style:(SFTileStyle)st items:(NSArray *)items;
+ (instancetype)grid:(NSString *)title style:(SFTileStyle)st items:(NSArray *)items;
@end

@interface SFPage : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *themeName;
@property (nonatomic, copy) NSString *backdrop;
@property (nonatomic, copy) NSArray *shelves;
@property (nonatomic, copy) NSString *emptyText;
@property (nonatomic) NSUInteger focusShelf;       // initial focus (e.g. episodes instead of the season picker above)
+ (instancetype)page:(NSString *)title theme:(NSString *)theme shelves:(NSArray *)shelves;
@end

// Resolve "prefix:id" to playback URLs through the owning app (SFApp resolve:). Online = skip
// local copies (items with streamOnly, "Online abspielen").
void SFResolveRef(NSString *ref, SFURLDone done);
void SFResolveRefOnline(NSString *ref, SFURLDone done);

NSError *SFError(NSString *msg);
// Local copy for a source ID (set by SFDownloads): a downloaded file, or the item complete in the media
// store (a local URL) - resolveURL then plays it without the source.
void SFSetLocalCopyLookup(NSURL *(^lookup)(NSString *identifier));
