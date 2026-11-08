// Offline layer ("premium"): downloading is a state of an item, not a separate program - its tracks
// in the media store, pinned (docs/media-store.md: buffer and download are one). Applies to all
// sources; metadata in the DB (tables downloads/subscriptions). Identity = source ID (yt:…, zdf:…,
// ard:…, orf:…), hence shared progress online/offline. Subscriptions pre-buffer new episodes.
#import "SFModel.h"
#import "SFApp.h"
#import "SFDownloadRecord.h"   // SFDLState, the record of one download
@class SFFollow;

extern NSString *const SFDownloadsDidChangeNotification;   // object = identifier (or nil = many)
// storage became full or free again, an online check finished ("Platz schaffen" page reloads)
extern NSString *const SFDownloadsStorageDidChangeNotification;
extern NSString *const SFUnsortedChannel;   // show name for videos without a channel

// Feeds (newest episodes of a show/channel, newest first) come from the owning app (SFApp feed:).
typedef void (^SFFeedDone)(NSArray *items, NSError *e);
BOOL SFHasFeed(NSString *ref);                  // "prefix:id" is a show ref whose app has a feed
void SFFetchFeed(NSString *ref, SFFeedDone done);
// feed from a page loader (show page): all videos of the page, newest first - for apps whose
// show page already lists the episodes
void SFFeedFromPage(SFPageLoader loader, SFFeedDone done);
// The fill, download pause and online check: SFApp fillItem: (else the media proxy fills what the
// app resolves to), backgroundPausedUntil, availabilityOfItem: (without a check the app's online
// resolver answers: a resolvable stream = online).

@class SFMediaStore;

@interface SFDownloads : NSObject
+ (instancetype)shared;
// The media store (docs/media-store.md): buffered and downloaded bytes by track, under the downloads
// root (.store); it keeps the storage reserve free and never evicts a downloaded item
@property (nonatomic, readonly) SFMediaStore *mediaStore;
- (void)start;                                   // queue + subscription check
- (void)stopForExit;                             // let go of the running fill (it resumes on the next start)

// Single items
- (SFDLState)stateFor:(NSString *)identifier progress:(double *)progress;
- (BOOL)willRetry:(NSString *)identifier;   // failed subscription episode, another attempt follows
- (BOOL)isPrebuffered:(NSString *)identifier;   // a subscription episode filled for a while (expires), not a download the user keeps
- (SFItem *)itemFor:(NSString *)identifier;      // downloaded content as an item (local)
- (void)download:(SFItem *)item;
// The same, and what to tell the user (main queue): what is still missing when part of it is on disk
// already ("noch 340 MB"), or that nothing is (docs/media-store.md)
- (void)download:(SFItem *)item told:(void (^)(NSString *message))told;
- (void)remove:(NSString *)identifier;           // cancel, or delete it (its tracks leave the store)
- (NSArray *)items:(NSString *)source;           // finished downloads (SFItem, newest first); nil = all
- (NSArray *)active;                             // running/waiting (SFItem)
@property (nonatomic, readonly) NSUInteger generation;   // changes on every state change (not on progress)
- (unsigned long long)bytesOf:(NSString *)ident;         // its bytes in the media store (any thread, never waits)
- (unsigned long long)bytesUsedFor:(NSString *)source;   // the finished downloads' bytes; nil = all
- (unsigned long long)freeBytes;                           // free space on the storage volume
- (NSString *)storageSummary:(NSString *)source;           // "398 GB belegt · 262 GB frei"
- (NSUInteger)removeAllOfChannel:(NSString *)channel source:(NSString *)source;   // number of deleted downloads (kept ones stay)
- (SFDownloadRecord *)recordFor:(NSString *)identifier;   // finished download (a copy); nil otherwise
- (NSString *)folderForSource:(NSString *)source channel:(NSString *)channel;   // folder of a show in Sofa's storage

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
// the same, but its database writes are returned for the caller's transaction (SFStore runAll:)
- (NSArray *)unsubscribeWrites:(NSString *)folderIdentifier;
- (BOOL)canSubscribe:(SFItem *)folder;           // is there a feed for this folder type?
- (void)checkSubscriptionsNow;
- (NSString *)subscriptionIDForChannel:(NSString *)channel source:(NSString *)source;

@end
