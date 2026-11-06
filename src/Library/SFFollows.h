// "Folgen" (follows): channels/shows the household follows – across all apps, without sign-in, shared.
// Core of the concept (NOTES "Folgen statt Download-Abos"): followed shows feed "Neue Folgen"
// (streamed) and "Meine Sendungen & Kanäle". "Automatisch herunterladen" (SFDownloads subscription) is
// only an optional add-on per followed show and requires following.
// New episodes are fetched in the background (every 30 min, one after another) and cached so Home
// appears instantly – not 128 requests on every open.
#import "SFModel.h"

extern NSString *const SFFollowsDidChangeNotification;

// build the page of a show/channel from its identifier (registered per provider)
SFPageLoader SFShowPageLoader(NSString *ref, NSString *title);   // nil if no page is registered for the type
// determine an episode's show/channel after the fact (items without showRef, e.g. older saved ones)
typedef void (^SFShowRefLookup)(SFItem *item, void (^done)(NSString *ref));
SFShowRefLookup SFShowRefLookupFor(NSString *source);   // the app's showRefForItem:, nil if it has none

@interface SFFollows : NSObject
+ (instancetype)shared;
- (void)start;                                         // migration + background refresh
- (BOOL)canFollow:(SFItem *)folder;                    // is there a feed + page for this type?
- (BOOL)isFollowing:(NSString *)identifier;
- (void)follow:(SFItem *)folder;
- (void)unfollow:(NSString *)identifier;               // also ends "Automatisch herunterladen"
- (NSArray *)follows:(NSString *)source;               // SFItem folders (alphabetical), nil = all
- (BOOL)needsImage:(NSString *)identifier;             // followed, but without a usable picture
- (void)setImage:(NSString *)url forFollow:(NSString *)identifier;   // the app's current picture (written only when it changed)
- (NSArray *)latest:(NSInteger)n source:(NSString *)source;   // newest episodes of followed shows
- (void)refreshNow;
@end
