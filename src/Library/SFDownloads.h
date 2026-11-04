// Offline layer ("premium"): downloading is a state of an item, not a separate program.
// Applies to all sources. Files in Sofa's own storage (~/Movies/Sofa), metadata in the DB
// (tables downloads/subscriptions). Identity = source ID (yt:…, zdf:…, ard:…, orf:…),
// hence shared progress online/offline.
// Subscriptions ("download new episodes automatically") replace ytdl-sub.
#import "SFModel.h"

extern NSString *const SFDownloadsDidChangeNotification;   // object = identifier (or nil = many)
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
- (NSUInteger)removeAllOfChannel:(NSString *)channel source:(NSString *)source;   // number of deleted downloads
- (NSString *)folderForSource:(NSString *)source channel:(NSString *)channel;   // folder of a show in Sofa's storage

// Migration (one-time): adopt an existing file (moved into Sofa's storage)
- (BOOL)adoptFile:(NSString *)path item:(SFItem *)item thumb:(NSString *)thumb subscription:(NSString *)subID error:(NSError **)err;
@end

// Subscriptions (auto-download a channel/show) – SFDownloads+Subscriptions.m
@interface SFDownloads (Subscriptions)
- (BOOL)isSubscribed:(NSString *)folderIdentifier;
- (void)subscribe:(SFItem *)folder;              // folder.identifier = "ytchannel:UC…", "zdfshow:…", …
- (void)unsubscribe:(NSString *)folderIdentifier;
- (BOOL)canSubscribe:(SFItem *)folder;           // is there a feed for this folder type?
- (NSArray *)subscriptions;                      // Dictionaries (id, source, title, image, keepDays)
- (void)checkSubscriptionsNow;
- (NSString *)subscriptionIDForChannel:(NSString *)channel source:(NSString *)source;
// Smart Downloads: delete watched subscription episodes 1 day after watching (default: on; manual ones never)
@property (nonatomic) BOOL deletesWatched;

// Migration (one-time): adopt a subscription
- (void)addSubscriptionRecord:(NSDictionary *)rec;   // id, source, title, image, keepDays
@end
