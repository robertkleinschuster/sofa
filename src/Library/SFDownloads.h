// Offline layer ("premium"): downloading is a state of an item, not a separate program.
// Applies to all sources. Files in Sofa's own storage (~/Movies/Sofa), metadata in the DB
// (tables downloads/subscriptions). Identity = source ID (yt:…, zdf:…, ard:…, orf:…),
// hence shared progress online/offline.
// Subscriptions ("download new episodes automatically") replace ytdl-sub.
#import "SFModel.h"

extern NSString *const SFDownloadsDidChangeNotification;   // object = identifier (or nil = many)
// storage became full or free again, an online check finished ("Platz schaffen" page reloads)
extern NSString *const SFDownloadsStorageDidChangeNotification;
extern NSString *const SFUnsortedChannel;   // show name for videos without a channel

typedef NS_ENUM(NSInteger, SFDLState) {
    SFDLNone = -1,
    SFDLQueued = 0,
    SFDLRunning = 1,
    SFDLDone = 2,
    SFDLFailed = 3,
    SFDLDismissed = 4,     // deleted by the user -> the subscription does not download it again
};

// Delivers the newest episodes of a subscription (channel/show), newest first.
typedef void (^SFFeedFetcher)(NSString *ref, void (^done)(NSArray *items, NSError *e));
void SFRegisterFeed(NSString *prefix, SFFeedFetcher f);
SFFeedFetcher SFFeedFor(NSString *identifier);   // registered feed for "prefix:ref" (or nil)
// feed from a page loader (show page): all videos of the page, newest first
void SFRegisterFeedFromLoader(NSString *prefix, SFPageLoader (^loaderFor)(NSString *ref));
// Optional: custom download URL (e.g. YouTube 720p instead of the 1080p stream)
// audio: optional separate audio track (e.g. YouTube original audio instead of the default track in the muxed stream)
typedef void (^SFDownloadURLDone)(NSURL *url, NSURL *audio, NSError *e);
typedef void (^SFDownloadURLFetcher)(SFItem *item, SFDownloadURLDone done);
void SFRegisterDownloadURL(NSString *prefix, SFDownloadURLFetcher f);
// Optional: until when a source must not be asked for downloads (epoch, 0 = now is fine), e.g.
// YouTube during a bot-check pause. Its queued downloads wait without using up attempts.
typedef NSTimeInterval (^SFDownloadPause)(void);
void SFRegisterDownloadPause(NSString *prefix, SFDownloadPause f);
// Optional: is this downloaded video still online at its source? (for "Platz schaffen": what is not
// online any more is irreplaceable). online: 1 yes, 0 no (deleted/private/expired), -1 unknown
// (network error - ask again later). Without a registered check the source's online resolver
// answers (a resolvable stream = online).
typedef void (^SFAvailabilityDone)(NSInteger online);
typedef void (^SFAvailabilityCheck)(SFItem *item, SFAvailabilityDone done);
void SFRegisterAvailabilityCheck(NSString *prefix, SFAvailabilityCheck f);

@interface SFDownloads : NSObject
+ (instancetype)shared;
- (void)start;                                   // queue + subscription check
- (void)stopForExit;                             // terminate the running ffmpeg before the app exits (no orphans)

// Single items
- (SFDLState)stateFor:(NSString *)identifier progress:(double *)progress;
- (BOOL)willRetry:(NSString *)identifier;   // failed subscription episode, another attempt follows
- (NSString *)fileFor:(NSString *)identifier;   // finished file (exists) or nil
- (SFItem *)itemFor:(NSString *)identifier;      // downloaded content as an item (local)
- (void)download:(SFItem *)item;
- (void)remove:(NSString *)identifier;           // cancel, or delete the file
- (NSArray *)items:(NSString *)source;           // finished downloads (SFItem, newest first); nil = all
- (NSArray *)active;                             // running/waiting (SFItem)
@property (nonatomic, readonly) NSUInteger generation;   // changes on every state change (not on progress)
- (unsigned long long)bytesUsedFor:(NSString *)source;   // nil = all
- (unsigned long long)freeBytes;                           // free space on the storage volume
- (NSString *)storageSummary:(NSString *)source;           // "398 GB belegt · 262 GB frei"
- (NSUInteger)removeAllOfChannel:(NSString *)channel source:(NSString *)source;   // number of deleted downloads (kept ones stay)
- (NSDictionary *)recordFor:(NSString *)identifier;   // finished download: bytes, added, published, channel, source, keep
- (NSString *)folderForSource:(NSString *)source channel:(NSString *)channel;   // folder of a show in Sofa's storage

// Migration (one-time): adopt an existing file (moved into Sofa's storage)
- (BOOL)adoptFile:(NSString *)path item:(SFItem *)item thumb:(NSString *)thumb subscription:(NSString *)subID error:(NSError **)err;
@end

// Storage (SFDownloads+Storage.m) - downloads are never deleted automatically
@interface SFDownloads (Storage)
// Storage guard: below the reserve no download starts, and a running one stops (back into the
// queue, no attempt used); it continues by itself once there is room again. Never deletes anything.
@property (nonatomic, readonly) BOOL storageFull;
@property (nonatomic, readonly) unsigned long long storageReserve;   // bytes kept free
- (void)setStorageReserveForTesting:(unsigned long long)bytes;      // dev instances only

// "Behalten": never offered for deletion in bulk ("Platz schaffen"), never removed with a show.
- (BOOL)isKept:(NSString *)identifier;
- (void)setKept:(BOOL)kept forIdentifier:(NSString *)identifier;

// Online availability of a download: 1 online, 0 gone, -1 not checked yet / unknown. Cached 30 days.
- (NSInteger)onlineStateFor:(NSString *)identifier;
// check these (finished downloads; cached ones are skipped), one after another with spacing; progress
// via SFDownloadsStorageDidChangeNotification, done when all have an answer (or the run was cut short)
- (void)checkOnline:(NSArray *)identifiers done:(dispatch_block_t)done;
// with a shorter trust window: bulk deletion re-verifies anything older than this right before deleting
- (NSInteger)onlineStateFor:(NSString *)identifier maxAge:(NSTimeInterval)maxAge;
- (void)checkOnline:(NSArray *)identifiers maxAge:(NSTimeInterval)maxAge done:(dispatch_block_t)done;

@end

// Subscriptions (auto-download a channel/show) – SFDownloads+Subscriptions.m
@interface SFDownloads (Subscriptions)
- (BOOL)isSubscribed:(NSString *)folderIdentifier;
- (void)subscribe:(SFItem *)folder;              // folder.identifier = "ytchannel:UC…", "zdfshow:…", …
- (void)unsubscribe:(NSString *)folderIdentifier;
- (BOOL)canSubscribe:(SFItem *)folder;           // is there a feed for this folder type?
- (NSArray *)subscriptions;                      // Dictionaries (id, source, title, image, keepDays = download window)
- (void)checkSubscriptionsNow;
- (NSString *)subscriptionIDForChannel:(NSString *)channel source:(NSString *)source;

// Migration (one-time): adopt a subscription
- (void)addSubscriptionRecord:(NSDictionary *)rec;   // id, source, title, image, keepDays
@end
