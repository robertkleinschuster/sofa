// YouTube's pages in Sofa: start page, channel, playlist, search. Parsed items become what Sofa
// shows here - folders open their page, videos that are downloaded play their local copy.
#import "SFModel.h"

@interface SFYTPages : NSObject
+ (NSArray *)shown:(NSArray *)parsed;    // SFYTParser items as Sofa shows them (see above)
+ (SFItem *)itemForVideoID:(NSString *)videoID title:(NSString *)title thumb:(NSString *)thumb;   // local copy preferred; title/thumb may be nil
+ (SFPageLoader)homeLoader;
+ (SFPageLoader)channelLoader:(NSString *)channelID title:(NSString *)title;
+ (SFPageLoader)playlistLoader:(NSString *)playlistID title:(NSString *)title;
+ (SFPageLoader)searchLoader:(NSString *)query;
+ (void)suggestions:(NSString *)prefix done:(void (^)(NSArray *))done;
@end
