// Einheitliches Datenmodell aller Quellen: Item (Video, Ordner, Live, Aktion),
// Shelf (Reihe/Raster von Items) und Page (ein Bildschirm voller Shelves).
#import "SFCore.h"
#import "SFTheme.h"

typedef NS_ENUM(NSInteger, SFItemKind) {
    SFItemVideo,     // abspielbar
    SFItemLive,      // Livestream (keine Fortsetzen-Position)
    SFItemFolder,    // öffnet eine Page (Sendung, Kanal, Rubrik)
    SFItemAction,    // führt Block aus (App starten, Einstellung, ...)
};

typedef NS_ENUM(NSInteger, SFShelfLayout) {
    SFShelfRail,     // horizontale Reihe
    SFShelfGrid,     // umbrechendes Raster
};

@class SFPage, SFItem;
typedef void (^SFPageDone)(SFPage *page, NSError *error);
typedef void (^SFPageLoader)(SFPageDone done);
typedef void (^SFURLDone)(NSURL *url, NSError *error);
typedef void (^SFResolver)(SFURLDone done);

@interface SFItem : NSObject <NSCopying>
@property (nonatomic) SFItemKind kind;
@property (nonatomic, copy) NSString *identifier;      // stabil, für Fortsetzen/Verlauf
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;        // z.B. Kanal · Datum
@property (nonatomic, copy) NSString *plot;
@property (nonatomic, copy) NSString *image;           // Pfad oder URL
@property (nonatomic, copy) NSString *backdrop;        // großes Hintergrundbild
@property (nonatomic, copy) NSString *channel;         // Sendung / Kanal
@property (nonatomic, copy) NSString *source;          // Theme-ID der Herkunft
@property (nonatomic, copy) NSString *badge;           // "LIVE", "NEU", "UT", ...
@property (nonatomic, strong) NSDate *date;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic) SFTileStyle style;
@property (nonatomic, strong) NSURL *playURL;
@property (nonatomic, copy) SFResolver resolver;       // falls URL erst ermittelt werden muss
@property (nonatomic, copy) NSString *resolverRef;     // "provider:ref" (persistierbar)
@property (nonatomic, copy) SFPageLoader pageLoader;   // für Folder
@property (nonatomic, copy) dispatch_block_t action;   // für Action
@property (nonatomic, strong) NSColor *tint;           // Kachelfarbe (App-Kacheln)
@property (nonatomic, copy) NSString *themeName;       // Theme der geöffneten Page
@property (nonatomic, copy) NSString *localPath;       // heruntergeladene Datei
@property (nonatomic) BOOL streamOnly;                 // online abspielen, auch wenn ein Download existiert („Online abspielen“); nicht gespeichert
@property (nonatomic) BOOL inDownloadsList;            // Kachel der Downloads-Seite (dort kein „Offline“-Chip nötig); nicht gespeichert
@property (nonatomic, copy) NSString *playlistID;      // aus einer Playlist geöffnet: „Als Nächstes“ = nächstes Video der Playlist
@property (nonatomic, copy) NSString *heroTitle;       // Hero-Titel statt title (z. B. Kanalname über einer Aktions-Kachel)
@property (nonatomic, copy) NSString *heroMeta;        // Hero-Metazeile statt Kanal/Datum/Dauer
@property (nonatomic, copy) NSString *externalID;      // ID bei der Quelle (YouTube-Video-ID)
@property (nonatomic, copy) NSString *showRef;         // Sendung/Kanal der Folge („ytchannel:UC…“, „zdfshow:…“) → „Zur Sendung“
@property (nonatomic) BOOL imageFit;
@property (nonatomic, copy) NSString *logo;            // res/logos/<name>.png (App-Kacheln)
@property (nonatomic) NSInteger logoVariant;           // SFLogoVariant                   // Bild einpassen statt füllen (Logos)

- (NSDictionary *)dictionaryRepresentation;
+ (instancetype)itemWithDictionary:(NSDictionary *)d;
- (void)resolveURL:(SFURLDone)done;    // playURL oder resolver oder Provider-Registry
@end

@interface SFShelf : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic) SFShelfLayout layout;
@property (nonatomic) SFTileStyle style;
@property (nonatomic, copy) NSArray *items;
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
@property (nonatomic) NSUInteger focusShelf;       // Startfokus (z. B. Folgen statt der Staffelauswahl darüber)
+ (instancetype)page:(NSString *)title theme:(NSString *)theme shelves:(NSArray *)shelves;
@end

// Provider registrieren sich mit Präfix; löst "prefix:ref" zu Abspiel-URLs auf.
typedef void (^SFRefResolver)(NSString *ref, SFURLDone done);
void SFRegisterResolver(NSString *prefix, SFRefResolver r);
void SFResolveRef(NSString *ref, SFURLDone done);

NSError *SFError(NSString *msg);
// Ausweich-URLs (z.B. YouTube: 1080p-HLS -> 720p-HLS -> 360p-MP4), falls AVFoundation die
// erste URL wiederholt nicht öffnet.
void SFSetAlternateURLs(NSURL *primary, NSArray *alternates);
// Offline-Kopie zu einer Quell-ID (von SFDownloads gesetzt): resolveURL spielt dann lokal.
void SFSetLocalFileLookup(NSString *(^lookup)(NSString *identifier));
NSURL *SFNextAlternateURL(NSURL *failed);
