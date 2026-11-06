// YouTube: pages built and parsed natively from InnerTube (WEB client), without sign-in; every
// request and all playback through the sofa-yt sidecar (one browser identity, SABR). Following channels = Sofa's own list (SFFollows).
// Reference: docs/youtube.md. The app's modules:
//   SFYTInnerTube  request + JSON shapes       SFYTParser  JSON -> items (pure, tools/test-parse)
//   SFYTPages      pages (home, channel, …)    SFYTWatch   one video: watch page, details, channel
//   SFYTFeeds      followed channels' feeds    SFYTSabr / SFYTBreaker  sidecar + bot-check pause
//   SFLounge / SFYTRemote / SFPairScreen  phone remote
// This class is the SFApp adapter (SFYouTubeApp.m, +Playback.m, +Dev.m).
#import "SFApp.h"

@interface SFYouTubeApp : NSObject <SFApp>
+ (void)resolveChannelURL:(NSString *)url done:(void (^)(NSString *channelID))done;   // @handle URL -> UC… (library import)
@end

// phone remote: one SFLounge command -> player host (SFYTRemote.m)
void SFYTRemoteCommand(id<SFPlayerHost> host, NSString *cmd, NSDictionary *args);
@class SFPlayerScreen;
// a phone queue's next entry gets its details (one watch page) when the one before it starts
void SFYTRemoteFillAhead(SFPlayerScreen *p);
