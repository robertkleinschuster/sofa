// What the TV tells the phone (YouTube Lounge "screen" messages): pure builders over the player's
// state. `video` = the YouTube video ID the phone may see (nil = nothing shared: idle state);
// `cpn` = the playback nonce of this screen. SFLounge decides what is shared and sends them.
#import "SFPlayerScreen.h"

@interface SFLoungeMessages : NSObject
+ (NSDictionary *)stateOf:(SFPlayerScreen *)p video:(NSString *)video cpn:(NSString *)cpn;        // onStateChange
+ (NSDictionary *)nowPlayingOf:(SFPlayerScreen *)p video:(NSString *)video cpn:(NSString *)cpn;   // nowPlaying ({} = nothing)
+ (NSArray *)subtitles:(NSDictionary *)subtitleState video:(NSString *)video;                    // onSubtitlesTrackChanged
+ (NSArray *)volume;                                                                              // onVolumeChanged
+ (NSArray *)fullStateOf:(SFPlayerScreen *)p video:(NSString *)video cpn:(NSString *)cpn;        // greeting: all of the above
@end
