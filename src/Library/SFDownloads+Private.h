// SFDownloads – privater Teil: Ivars und gemeinsame Hilfen für SFDownloads.m (Persistenz,
// Abfragen, Warteschlange, ffmpeg-Lauf, Aktionen, Migration) und SFDownloads+Subscriptions.m
// (Abos, Feeds, Behaltefrist und Smart-Delete gesehener Folgen).
#import "SFDownloads.h"
#import "SFSettings.h"
#import "SFStore.h"
#import "SFCurl.h"
#import "SFNet.h"
#import "SFFollows.h"
#import "SFRuntime.h"

// Quell-ID "prefix:rest" zerlegen (yt:…, zdfshow:…)
static inline NSString *prefixOf(NSString *ref) { NSRange r = [ref rangeOfString:@":"]; return r.location == NSNotFound ? nil : [ref substringToIndex:r.location]; }
static inline NSString *restOf(NSString *ref) { NSRange r = [ref rangeOfString:@":"]; return r.location == NSNotFound ? ref : [ref substringFromIndex:NSMaxRange(r)]; }

@interface SFDownloads () {
    NSMutableDictionary *_recs;      // id -> NSMutableDictionary (Spalten der Tabelle downloads)
    NSMutableDictionary *_subs;      // id -> NSMutableDictionary
    NSTask *_task;
    NSString *_runningID;
    BOOL _started, _checking;
    NSTimer *_checkTimer;
    NSMutableDictionary *_itemCache; // id -> SFItem (aus JSON), ungültig bei save:
    NSUInteger _generation;          // Speicher der Property generation (auch für die Abo-Kategorie)
}
- (void)save:(NSDictionary *)r;
- (void)changed:(NSString *)identifier;
- (BOOL)enqueue:(SFItem *)item sub:(NSString *)subID;   // NO = schon vorhanden/abgelehnt
- (void)pump;
- (SFItem *)itemFromRec:(NSDictionary *)r;
+ (NSString *)ffmpegToolPath;
+ (NSString *)root;
@end

// Integrity layer (SFDownloads+Integrity.m): orphan reaping, unique part files, verification, audit
@interface SFDownloads (Integrity)
- (NSUInteger)reapOrphans;
- (void)sweepStaleParts;
- (NSString *)partSuffix;
- (void)auditExistingDownloads;
+ (NSString *)problemWithFile:(NSString *)path expectedDuration:(double)expected ffmpeg:(NSString *)ff;
@end
