// YouTube "Link with TV code" (Lounge API, receiver side). Specification and live
// measurements: docs/youtube-lounge.md. Permanent pairing via a stored screenId;
// the bind channel runs in the background as long as Sofa runs.
// Long poll via libcurl (NSURLSession buffers the streamed body on 10.9).
#import "SFCore.h"

extern NSString *const SFLoungeRemotesDidChangeNotification;

@interface SFLounge : NSObject
+ (instancetype)shared;
- (void)start;
- (void)stop;                                        // on quit (best effort)
// New 12-digit TV code (valid ~5 min). done on the main thread.
- (void)fetchPairingCode:(void (^)(NSString *code, NSError *e))done;
@property (nonatomic, readonly) NSArray *remoteNames;   // connected phones
@property (nonatomic, readonly) BOOL online;            // bind session established
// Privacy with several users (settings, persisted):
@property (nonatomic) BOOL paused;              // connection paused: pairing stays, no commands, nothing is shared
@property (nonatomic) BOOL sharesAllPlayback;   // NO (default): only report playback started from the phone to the phone
- (void)forgetAllPhones;                        // unpair: new screenId, phones need a new code

// Commands coming from the phone (main thread). cmd: setPlaylist, play, pause, seekTo,
// next, previous, stopVideo, setVolume, setSubtitlesTrack, remoteConnected ...; args = payload (strings).
@property (nonatomic, copy) void (^commandHandler)(NSString *cmd, NSDictionary *args);
// Returns the currently visible player (or nil) - set by the app.
@property (nonatomic, copy) id (^playerProvider)(void);
@end
