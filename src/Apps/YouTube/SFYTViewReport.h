// Sofa's player -> the YouTube engine's view reporting (docs/youtube-engine.md "Playback reporting"):
// while a YouTube VOD plays from an engine session, the player's state (playing / paused /
// buffering / ended, position, time since the last key press) goes to the engine, which sends the
// view's stats pings like youtube.com's player. Leaving the video (closed, another video) ends the
// view. Local copies and lives report nothing.
#import <Foundation/Foundation.h>

@interface SFYTViewReport : NSObject
+ (void)start;   // once, at app start (main thread)
@end
