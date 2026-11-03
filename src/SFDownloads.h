// Offline-Schicht ("Premium"): Herunterladen ist ein Zustand eines Inhalts, kein eigenes
// Programm. Gilt für alle Quellen. Dateien in Sofa-eigenem Speicher (~/Movies/Sofa),
// Metadaten in der DB (Tabellen downloads/subscriptions). Identität = Quell-ID
// (yt:…, zdf:…, ard:…, orf:…), dadurch gemeinsamer Fortschritt online/offline.
// Abos ("Neue Folgen automatisch laden") ersetzen ytdl-sub.
#import "SFModel.h"

extern NSString *const SFDownloadsDidChangeNotification;   // object = identifier (oder nil = viele)

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
// Optional: eigene Download-URL (z.B. YouTube 720p statt 1080p-Stream)
typedef void (^SFDownloadURLFetcher)(SFItem *item, SFURLDone done);
void SFRegisterDownloadURL(NSString *prefix, SFDownloadURLFetcher f);

@interface SFDownloads : NSObject
+ (instancetype)shared;
- (void)start;                                   // Warteschlange + Abo-Prüfung

// Einzelne Inhalte
- (SFDLState)stateFor:(NSString *)identifier progress:(double *)progress;
- (NSString *)fileFor:(NSString *)identifier;   // fertige Datei (existiert) oder nil
- (SFItem *)itemFor:(NSString *)identifier;      // heruntergeladener Inhalt als Item (lokal)
- (void)download:(SFItem *)item;
- (void)remove:(NSString *)identifier;           // abbrechen bzw. Datei löschen
- (NSArray *)items:(NSString *)source;           // fertige Downloads (SFItem, neueste zuerst); nil = alle
- (NSArray *)active;                             // laufend/wartend (SFItem)
- (unsigned long long)bytesUsed;

// Abos (Kanal/Sendung automatisch laden)
- (BOOL)isSubscribed:(NSString *)folderIdentifier;
- (void)subscribe:(SFItem *)folder;              // folder.identifier = "ytchannel:UC…", "zdfshow:…", …
- (void)unsubscribe:(NSString *)folderIdentifier;
- (BOOL)canSubscribe:(SFItem *)folder;           // gibt es einen Feed für diesen Ordnertyp?
- (NSArray *)subscriptions;                      // Dictionaries (id, source, title, image, keepDays)
- (void)checkSubscriptionsNow;

// Migration (einmalig): vorhandene Datei übernehmen (wird in den Sofa-Speicher verschoben)
- (BOOL)adoptFile:(NSString *)path item:(SFItem *)item thumb:(NSString *)thumb subscription:(NSString *)subID error:(NSError **)err;
- (void)addSubscriptionRecord:(NSDictionary *)rec;   // id, source, title, image, keepDays
@end
