// Offline-Schicht ("Premium"): Herunterladen ist ein Zustand eines Inhalts, kein eigenes
// Programm. Gilt für alle Quellen. Dateien in Sofa-eigenem Speicher (~/Movies/Sofa),
// Metadaten in der DB (Tabellen downloads/subscriptions). Identität = Quell-ID
// (yt:…, zdf:…, ard:…, orf:…), dadurch gemeinsamer Fortschritt online/offline.
// Abos ("Neue Folgen automatisch laden") ersetzen ytdl-sub.
#import "SFModel.h"

extern NSString *const SFDownloadsDidChangeNotification;   // object = identifier (oder nil = viele)
extern NSString *const SFUnsortedChannel;   // Sendungsname für Videos ohne Kanal

typedef NS_ENUM(NSInteger, SFDLState) {
    SFDLNone = -1,
    SFDLQueued = 0,
    SFDLRunning = 1,
    SFDLDone = 2,
    SFDLFailed = 3,
    SFDLDismissed = 4,     // vom User gelöscht -> Abo lädt es nicht erneut
};

// Liefert die neuesten Folgen eines Abos (Kanal/Sendung), neueste zuerst.
typedef void (^SFFeedFetcher)(NSString *ref, void (^done)(NSArray *items, NSError *e));
void SFRegisterFeed(NSString *prefix, SFFeedFetcher f);
SFFeedFetcher SFFeedFor(NSString *identifier);   // registrierter Feed für "prefix:ref" (oder nil)
// Feed aus einem Seiten-Loader (Sendungsseite): alle Videos der Seite, neueste zuerst
void SFRegisterFeedFromLoader(NSString *prefix, SFPageLoader (^loaderFor)(NSString *ref));
// Optional: eigene Download-URL (z.B. YouTube 720p statt 1080p-Stream)
// audio: optionale eigene Tonspur (z.B. YouTube-Originalton statt der Standardspur im gemuxten Stream)
typedef void (^SFDownloadURLDone)(NSURL *url, NSURL *audio, NSError *e);
typedef void (^SFDownloadURLFetcher)(SFItem *item, SFDownloadURLDone done);
void SFRegisterDownloadURL(NSString *prefix, SFDownloadURLFetcher f);

@interface SFDownloads : NSObject
+ (instancetype)shared;
- (void)start;                                   // Warteschlange + Abo-Prüfung

// Einzelne Inhalte
- (SFDLState)stateFor:(NSString *)identifier progress:(double *)progress;
- (BOOL)willRetry:(NSString *)identifier;   // fehlgeschlagene Abo-Folge, neuer Versuch folgt
- (NSString *)fileFor:(NSString *)identifier;   // fertige Datei (existiert) oder nil
- (SFItem *)itemFor:(NSString *)identifier;      // heruntergeladener Inhalt als Item (lokal)
- (void)download:(SFItem *)item;
- (void)remove:(NSString *)identifier;           // abbrechen bzw. Datei löschen
- (NSArray *)items:(NSString *)source;           // fertige Downloads (SFItem, neueste zuerst); nil = alle
- (NSArray *)active;                             // laufend/wartend (SFItem)
@property (nonatomic, readonly) NSUInteger generation;   // ändert sich bei jeder Zustandsänderung (nicht bei Fortschritt)
- (unsigned long long)bytesUsedFor:(NSString *)source;   // nil = alle
- (unsigned long long)freeBytes;                           // freier Platz auf dem Speicher-Volume
- (NSString *)storageSummary:(NSString *)source;           // "398 GB belegt · 262 GB frei"
- (NSUInteger)removeAllOfChannel:(NSString *)channel source:(NSString *)source;   // Anzahl gelöschter Downloads
- (NSString *)folderForSource:(NSString *)source channel:(NSString *)channel;   // Ordner einer Sendung im Sofa-Speicher

// Migration (einmalig): vorhandene Datei übernehmen (wird in den Sofa-Speicher verschoben)
- (BOOL)adoptFile:(NSString *)path item:(SFItem *)item thumb:(NSString *)thumb subscription:(NSString *)subID error:(NSError **)err;
@end

// Abos (Kanal/Sendung automatisch laden) – SFDownloads+Subscriptions.m
@interface SFDownloads (Subscriptions)
- (BOOL)isSubscribed:(NSString *)folderIdentifier;
- (void)subscribe:(SFItem *)folder;              // folder.identifier = "ytchannel:UC…", "zdfshow:…", …
- (void)unsubscribe:(NSString *)folderIdentifier;
- (BOOL)canSubscribe:(SFItem *)folder;           // gibt es einen Feed für diesen Ordnertyp?
- (NSArray *)subscriptions;                      // Dictionaries (id, source, title, image, keepDays)
- (void)checkSubscriptionsNow;
- (NSString *)subscriptionIDForChannel:(NSString *)channel source:(NSString *)source;
// Smart Downloads: gesehene Abo-Folgen 1 Tag nach dem Ansehen löschen (Standard: an; manuelle nie)
@property (nonatomic) BOOL deletesWatched;

// Migration (einmalig): Abo übernehmen
- (void)addSubscriptionRecord:(NSDictionary *)rec;   // id, source, title, image, keepDays
@end
