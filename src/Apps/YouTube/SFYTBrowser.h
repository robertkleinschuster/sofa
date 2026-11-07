// The YouTube engine's browser (docs/youtube-engine.md): Firefox (port firefox-x11) on an invisible
// display of its own (Xvfb, port xorg-server-xvfb), started the way a user starts it - no remote
// agent: YouTube refuses a browser under remote control - on Sofa's engine profile, with the engine
// extension installed and pointed at Sofa's channel. One profile = one identity (cookies, storage).
// No orphans: a watcher ends browser and display when Sofa dies - after a grace in which the next
// Sofa takes the running browser over (an update, a crash: same page, no new attestation) - and a
// later launch ends whatever a run recorded next to the profile, still runs and is not taken over.
#import "SFCore.h"

@interface SFYTBrowser : NSObject
- (instancetype)initWithProfile:(NSString *)profileDir;
@property (nonatomic, readonly) BOOL available;   // Firefox, Xvfb and the built extension are there
@property (nonatomic, readonly) BOOL running;
// Seconds the browser outlives Sofa so that the next Sofa can take it over; 0 (default): it ends
// with Sofa, and a launch never takes one over (dev instances, tests).
@property (nonatomic) int handoverGrace;
// Takes over the browser an earlier Sofa left running (handoverGrace > 0), or prepares the profile
// (prefs, extension + its config) and starts display and browser, which opens
// https://www.youtube.com/. On a background queue; done on the main queue - adopted: the page was
// already loaded (and its engine possibly started), no new document will report itself.
- (void)launchWithChannelPort:(uint16_t)port token:(NSString *)token done:(void (^)(BOOL ok, BOOL adopted))done;
// Ends browser and display (blocking up to a few seconds), also within the grace. No onExit for a stop.
- (void)stop;
// A user's click on the browser's display (SFYTPointer: trusted events), `rect` in screen pixels.
// done(NO) when no display runs or the click could not be made. Main queue.
- (void)clickInRect:(CGRect)rect done:(void (^)(BOOL ok))done;
// One line per browser process (pid, %cpu, rss, command) - what the browser is doing right now,
// for the log when the page stops answering. Blocking (ps, ~50 ms); nil when it is not running.
- (NSString *)processSnapshot;
// The browser or its display ended on its own. Main queue.
@property (nonatomic, copy) void (^onExit)(NSString *why);
@end
