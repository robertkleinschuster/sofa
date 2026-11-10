// "Folgen" (follows): channels/shows the household follows – across all apps, without sign-in, shared.
// Core of the concept (NOTES "Folgen statt Download-Abos"): followed shows feed "Neue Folgen"
// (streamed) and "Meine Sendungen & Kanäle"; their lists come from the apps' feeds (SFFeed).
// New episodes are fetched in the background (every 30 min, one after another) and cached so Home
// appears instantly – not 128 requests on every open.
#import "SFModel.h"
#import "SFFeed.h"

extern NSString *const SFFollowsDidChangeNotification;
extern NSString *const SFFollowsNewItemsNotification;   // object = the follow's id: its list changed (new episodes/videos)

// build the page of a show/channel from its identifier (registered per provider)
SFPageLoader SFShowPageLoader(NSString *ref, NSString *title);   // nil if no page is registered for the type
// determine an episode's show/channel after the fact (items without showRef, e.g. older saved ones)
typedef void (^SFShowRefLookup)(SFItem *item, void (^done)(NSString *ref));
SFShowRefLookup SFShowRefLookupFor(NSString *source);   // the app's showRefForItem:, nil if it has none

// One followed show/channel (a row of follows).
@interface SFFollow : NSObject <NSCopying>
@property (nonatomic, copy) NSString *identifier;   // the show ref ("ytchannel:UC...", "zdfshow:...")
@property (nonatomic, copy) NSString *source;       // its app
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *image;        // URL or a local file; nil = none yet
@property (nonatomic) NSTimeInterval added;
@property (nonatomic) NSTimeInterval checked;       // last check (the spread refresh plan); 0 = never
+ (instancetype)followWithRow:(NSDictionary *)row;
+ (instancetype)followOf:(SFItem *)folder;          // a new follow of this show/channel folder
- (NSArray *)writeStatement;                        // @[sql, args]
@end

@interface SFFollows : NSObject
+ (instancetype)shared;
- (void)start;                                         // migration + the spread refresh plan (SFRefreshPlan)
// main thread, once the follows and their items are read (read on a queue at launch): what reads
// them right away waits here instead of holding the main thread (the methods below would block)
- (void)whenReady:(dispatch_block_t)block;
- (BOOL)canFollow:(SFItem *)folder;                    // is there a feed + page for this type?
- (BOOL)isFollowing:(NSString *)identifier;
- (void)follow:(SFItem *)folder;
- (void)unfollow:(NSString *)identifier;               // also ends "Automatisch herunterladen"
- (SFFollow *)recordOf:(NSString *)identifier;         // a copy; nil = not followed
// follow without checking now (imports: many at once would be a burst of requests) - the spread
// refresh plan checks it in its turn
- (void)adopt:(SFFollow *)record;
- (NSArray *)follows:(NSString *)source;               // SFItem folders (alphabetical), nil = all
- (BOOL)needsImage:(NSString *)identifier;             // followed, but without a usable picture
// For a source whose follows are channels (their picture is the channel's own): its stored items of
// a followed channel that name no channel picture get the follow's - items stored before they
// carried one, or from lists that name none. Idempotent, one statement in the background.
- (void)lendPicturesToItemsOf:(NSString *)source;
- (NSArray *)latest:(NSInteger)n source:(NSString *)source;   // newest episodes of followed shows
// the same for many (thousands: copying them is work): sorted and copied in the background once the
// follows are loaded; done runs on the main thread
- (void)latest:(NSInteger)n source:(NSString *)source done:(void (^)(NSArray *items))done;
- (NSArray *)itemsOf:(NSString *)identifier;           // a follow's newest episodes (newest first) as last checked
@end
