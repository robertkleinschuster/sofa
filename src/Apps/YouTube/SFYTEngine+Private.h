// Shared between SFYTEngine.m (lifecycle, API), SFYTEngine+Media.m (local media routes),
// SFYTEngine+Store.m (session table, media store), SFYTEngine+Fill.m (downloads), SFYTEngine+Lounge.m (the phone lounge's transport) and
// SFYTEngine+Calls.m (plain InnerTube calls).
#import "SFYTEngine.h"
#import "SFYTChannel.h"

@class SFLocalHTTP, SFYTBrowser, SFPlayerScreen;

typedef NS_ENUM(NSInteger, SFYTEngineState) { SFYTEngineIdle, SFYTEngineStarting, SFYTEngineReady };

@interface SFYTEngine () {
    SFLocalHTTP *_server;
    NSString *_channelFile;       // the channel's port and token, kept across starts (startServer)
    NSDictionary *_savedChannel;  // {port, token} as in the file
    SFYTBrowser *_browser;
    SFYTEngineState _state;
    NSUInteger _run;              // browser runs; stale callbacks of an earlier run are ignored
    NSUInteger _page;             // engine pages seen (a reload is a new page)
    NSDate *_launchedAt;
    NSInteger _failures;          // consecutive short runs
    NSTimeInterval _nextStartAt;  // restart backoff (epoch)
    BOOL _startPending;           // a start waits for the backoff to end
    NSMutableArray *_waiting;     // ^(BOOL ready) blocks
    NSMutableArray *_preloads;    // times of recent focus preloads
    BOOL _consentPending;         // a consent click is scheduled or in progress
    BOOL _aliveCheck;             // a liveness check after a timed-out call is running
    NSDate *_unresponsiveRestartAt;   // the last restart for an unresponsive page
    NSTimer *_memoryTimer;        // the browser's memory, watched while it runs (checkMemory)
    NSUInteger _idleHeavyChecks;  // memory checks in a row: past the idle limit, no session
    BOOL _refreshPending;         // an intentional page reload: calls queued, lounge polls ended on ready
    __weak SFPlayerScreen *_viewer;  // an open player: no age refresh while it plays or was just paused
    NSDate *_viewerPausedAt;      // when the open player last paused (nil: playing or none)
    NSDate *_staleRefreshAt;      // the last refresh of a document whose token stream protection refused
}
@property (nonatomic, readonly) dispatch_queue_t queue;   // the loopback server's: channel + media
@property (nonatomic, readonly) SFYTChannel *channel;
- (void)setState:(SFYTEngineState)state;
- (void)tellWaiting:(BOOL)ready;
- (void)runFailed:(NSString *)why;
// One engine call with its Reply unwrapped, on the engine queue: done(value, nil), or (nil, error)
// with code = the status the engine answered (504: no answer) and userInfo = its failure body
// (error, bot, ...; "unanswered" when the page did not answer).
- (void)request:(NSString *)method args:(NSArray *)args timeout:(NSTimeInterval)timeout done:(void (^)(id value, NSError *e))done;
// A call once the engine is ready; done on the main thread (SFYTEngine+Calls.m uses it).
- (void)call:(NSString *)method args:(NSArray *)args timeout:(NSTimeInterval)timeout done:(void (^)(id value, NSError *e))done;
// Rest (SFYTEngine+Rest.m): the browser ended for the night - any later use starts it again; its
// processes at background priority or back (asynchronous)
- (void)restStop;
- (void)setBrowserBackground:(BOOL)bg;
// The page's engine answers calls - readable from any queue (mirrors the main-queue state).
@property (atomic) BOOL ready;
// http://127.0.0.1:<port> of the loopback server (started if it was not); nil when it can't run
@property (nonatomic, readonly) NSString *mediaBase;
// The engine's open with its request as sent (SFYTEngine.m); done on main.
- (void)open:(NSString *)vid request:(NSDictionary *)req done:(void (^)(NSDictionary *r, NSError *e))done;
@end

@interface SFYTEngine (LoungeEvents)   // implemented in SFYTEngine+Lounge.m
- (void)loungeEvent:(NSDictionary *)e;   // a `lounge` event of the page (main queue)
- (void)endLoungePolls;                  // the page went away: every running poll ends (status 0)
@end

@interface SFYTEngine (Media)
// GET|HEAD /s/<sid>/... (SFYTEngine+Media.m). Engine queue.
- (void)serveSession:(SFHTTPExchange *)x;
// A piece of a session's track: from the store when there, else from the engine (then kept). Engine queue.
- (void)read:(NSString *)sid track:(NSString *)key at:(long long)offset max:(NSUInteger)max
        done:(void (^)(NSData *bytes, long long total, NSString *mime, NSError *e))done;
@end

@interface SFYTEngine (Store)   // SFYTEngine+Store.m; any queue
// A session's table entry: its video and tracks (local key -> {id, total, mimeType}); stored = served
// from the store alone (no engine session behind it)
- (void)noteSession:(NSString *)sid video:(NSString *)vid stored:(BOOL)stored tracks:(NSDictionary *)tracks;
- (NSDictionary *)trackInfo:(NSString *)key session:(NSString *)sid;
// The player's requests on a session's track, newest wins (one track is one stream of the player,
// read sequentially): begin = the new request's number (0 = session not in the table, never
// superseded); superseded = a newer request on the track has begun since.
- (NSUInteger)beginRequestOn:(NSString *)key session:(NSString *)sid;
- (BOOL)request:(NSUInteger)n supersededOn:(NSString *)key session:(NSString *)sid;
- (BOOL)isStoredSession:(NSString *)sid;
- (NSString *)videoOfSession:(NSString *)sid;
- (void)noteOpened:(NSDictionary *)answer;          // an engine open answer: table entry + the item's manifest
- (NSDictionary *)storedAnswer:(NSString *)vid;     // a stored session when the item is complete; nil otherwise (main queue)
- (BOOL)openStored:(NSString *)vid done:(void (^)(NSDictionary *r, NSError *e))done;   // answered from the store: YES
- (void)subtitles:(NSString *)key session:(NSString *)sid done:(void (^)(NSString *vtt, NSError *e))done;
@end

@interface SFYTEngine (Refresh)
- (void)refreshIdlePage;
- (void)tokenRejected:(NSString *)videoId;
- (void)refreshPlayerChanged:(NSNotification *)n;
@end
