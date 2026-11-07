// The YouTube engine's browser (docs/youtube-engine.md): Firefox (port firefox-x11) on an invisible
// display of its own (Xvfb, port xorg-server-xvfb), started the way a user starts it - no remote
// agent: YouTube refuses a browser under remote control - on Sofa's engine profile, with the engine
// extension installed and pointed at Sofa's channel. One profile = one identity (cookies, storage).
// A run's processes are recorded next to the profile; a later launch ends what a crashed Sofa left.
#import "SFCore.h"

@interface SFYTBrowser : NSObject
- (instancetype)initWithProfile:(NSString *)profileDir;
@property (nonatomic, readonly) BOOL available;   // Firefox, Xvfb and the built extension are there
@property (nonatomic, readonly) BOOL running;
// Prepares the profile (prefs, extension + its config) and starts display and browser on a
// background queue; done(ok) on the main queue. The browser opens https://www.youtube.com/.
- (void)launchWithChannelPort:(uint16_t)port token:(NSString *)token done:(void (^)(BOOL ok))done;
// Ends browser and display (blocking up to a few seconds). No onExit for a stop.
- (void)stop;
// The browser or its display ended on its own. Main queue.
@property (nonatomic, copy) void (^onExit)(NSString *why);
@end
