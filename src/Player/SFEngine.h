// Playback engines behind SFPlayerScreen (docs/codecs-research.md):
//  - SFMPVEngine: libmpv (VP9/AV1/Opus, DASH, HLS, H.264 in software) - default since 2026-11-04;
//                 weakly linked (optional).
//  - SFAVEngine:  AVFoundation (hardware H.264, HLS) - fallback when mpv fails, and via the
//                 emergency switch SFPreferAVFoundation (defaults) the old choice.
// The screen only knows this protocol: OSD, progress, remote stay engine-independent.
#import "SFCore.h"

typedef NS_ENUM(NSInteger, SFEngineStatus) {
    SFEngineLoading = 0,
    SFEngineReady,
    SFEngineFailed,
};

@protocol SFEngineDelegate <NSObject>
- (void)engineStatusChanged;      // Loading -> Ready/Failed
- (void)engineRateChanged;        // Play/Pause
- (void)engineBufferingChanged;   // likelyToKeepUp changed
- (void)engineDidEnd;             // end reached
- (void)engineInterrupted;        // stream aborted midway
- (void)engineTick;               // ~2x per second during playback
@end

@protocol SFEngine <NSObject>
@property (nonatomic, weak) id<SFEngineDelegate> delegate;
@property (nonatomic, readonly) CALayer *videoLayer;       // attached by the screen, the screen sets the frame
@property (nonatomic, readonly) SFEngineStatus status;
@property (nonatomic, readonly) NSError *error;
@property (nonatomic, readonly) BOOL playing;              // running (rate > 0)
@property (nonatomic, readonly) BOOL likelyToKeepUp;
@property (nonatomic, readonly) NSTimeInterval currentTime;
@property (nonatomic, readonly) NSTimeInterval duration;   // 0 = unknown/live
@property (nonatomic, readonly) NSTimeInterval bufferedUntil;
@property (nonatomic) BOOL muted;
@property (nonatomic, readonly) NSString *engineName;      // for the log
// audioURL: separate audio track (DASH); mpv only. start: start position (exact), paused: don't start playing
- (void)openURL:(NSURL *)url audioURL:(NSURL *)audioURL start:(NSTimeInterval)start exact:(BOOL)exact paused:(BOOL)paused;
- (void)play;
- (void)pause;
- (void)seekTo:(NSTimeInterval)t exact:(BOOL)exact;
- (void)close;                    // stop playback (engine stays usable)
- (void)shutdown;                 // release for good - call BEFORE letting go (mpv: detach thread callbacks)
@optional
// Audio/subtitle tracks (mpv only). type = @"audio" | @"sub". Entries: id (NSNumber), lang, title,
// selected (BOOL), url (external tracks only).
- (NSArray *)tracksOfType:(NSString *)type;
- (void)selectTrack:(NSString *)type trackID:(NSInteger)tid;   // 0 = off
// Load and select an external track (e.g. YouTube subtitles as WebVTT, another language version);
// if the same URL was already loaded, it is only selected.
- (void)addTrack:(NSString *)type url:(NSURL *)url title:(NSString *)title lang:(NSString *)lang;
@end

// mpv source for a resolved URL (e.g. YouTube DASH: video/audio/height/fps/hlsHeight/hlsFps)
void SFSetMPVSource(NSURL *forURL, NSDictionary *source);
NSDictionary *SFMPVSourceFor(NSURL *url);
BOOL SFMPVAvailable(void);        // libmpv present at runtime?
