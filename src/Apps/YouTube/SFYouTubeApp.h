// YouTube: browsing 100 % native via InnerTube (WEB client), without sign-in; playback via the
// sofa-yt sidecar (SABR), yt-dlp as fallback. Following channels = Sofa's own list (SFFollows).
// Reference: docs/youtube.md. The app's modules:
//   SFYTInnerTube  request + JSON shapes       SFYTParser  JSON -> items (pure, tools/test-parse)
//   SFYTPages      pages (home, channel, …)    SFYTWatch   one video: watch page, details, channel
//   SFYTFeeds      followed channels' feeds    SFYTSabr / SFYTResolver / SFYTBreaker  playback paths
//   SFLounge / SFYTRemote / SFPairScreen  phone remote
// This class is the SFApp adapter (SFYouTubeApp.m, +Playback.m, +Dev.m).
#import "SFApp.h"

@interface SFYouTubeApp : NSObject <SFApp>
+ (void)resolveChannelURL:(NSString *)url done:(void (^)(NSString *channelID))done;   // @handle URL -> UC… (library import)
@end

// phone remote: one SFLounge command -> player host (SFYTRemote.m)
void SFYTRemoteCommand(id<SFPlayerHost> host, NSString *cmd, NSDictionary *args);
