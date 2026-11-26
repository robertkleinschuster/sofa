// SFWebTV - "Auf dem Fernseher abspielen" for Sofa im Browser (docs/pwa.md §6). An item from the browser
// opens in the TV's own player through the shell's player host, exactly as when chosen with the remote:
// SFPlayerScreen resumes, keeps the history and the marks, autoplays as always. The screen wakes as for
// the phone remote (SFPlayerHost wakeAndFront; playing ends a rest). The browser's own stream of that item
// ends first - one player per video and person (YouTube: never a second session of the same video for
// someone who moved it to the TV). Also what the TV plays, for the browser's "Läuft am Fernseher", and
// play / pause / stop for it. Main thread.
#import "SFModel.h"
#import "SFPlayerHost.h"

@interface SFWebTV : NSObject
+ (instancetype)shared;
@property (nonatomic, weak) id<SFPlayerHost> host;   // the shell's, at launch; nil = no TV (answers 503)
// Plays `item` on the TV. `at` > 0: from there (a playback handed over from the browser); else
// `fromStart` or, as the remote does, from the stored position. Another video playing on the TV is
// replaced only with `replace` - else done(409, {error, busy: {title}}). The same video already playing
// is not reopened (it plays on, at `at` if given). done(200, {tv: -state}) or (status, {error}).
- (void)play:(SFItem *)item fromStart:(BOOL)fromStart at:(NSTimeInterval)at replace:(BOOL)replace device:(NSString *)device
        done:(void (^)(NSInteger status, NSDictionary *answer))done;
// What the TV's player shows: {item, state: playing|paused|buffering|ended|failed, position, duration, live};
// nil = no player on the TV.
- (NSDictionary *)state;
// play | pause | stop (stop leaves the player as MENU does: the position is kept). 404 = no player, 400 = unknown.
- (NSInteger)control:(NSString *)action;
@end
