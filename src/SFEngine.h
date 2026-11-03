// Abspiel-Engines hinter SFPlayerScreen (docs/codecs-research.md):
//  - SFAVEngine:  AVFoundation (Hardware-H.264, HLS) – Standard
//  - SFMPVEngine: libmpv (VP9/AV1/Opus, DASH, HLS v7, fMP4 …) – wenn AVFoundation das Format
//                 nicht kann oder schlechtere Qualität liefert; schwach gelinkt (optional).
// Der Screen kennt nur dieses Protokoll: OSD, Fortschritt, Remote bleiben engine-unabhängig.
#import "SFCore.h"

typedef NS_ENUM(NSInteger, SFEngineStatus) {
    SFEngineLoading = 0,
    SFEngineReady,
    SFEngineFailed,
};

@protocol SFEngineDelegate <NSObject>
- (void)engineStatusChanged;      // Loading -> Ready/Failed
- (void)engineRateChanged;        // Play/Pause
- (void)engineBufferingChanged;   // likelyToKeepUp geändert
- (void)engineDidEnd;             // Ende erreicht
- (void)engineInterrupted;        // Stream mitten drin abgebrochen
- (void)engineTick;               // ~2x pro Sekunde während Wiedergabe
@end

@protocol SFEngine <NSObject>
@property (nonatomic, weak) id<SFEngineDelegate> delegate;
@property (nonatomic, readonly) CALayer *videoLayer;       // vom Screen eingehängt, Frame setzt der Screen
@property (nonatomic, readonly) SFEngineStatus status;
@property (nonatomic, readonly) NSError *error;
@property (nonatomic, readonly) BOOL playing;              // läuft (rate > 0)
@property (nonatomic, readonly) BOOL likelyToKeepUp;
@property (nonatomic, readonly) NSTimeInterval currentTime;
@property (nonatomic, readonly) NSTimeInterval duration;   // 0 = unbekannt/live
@property (nonatomic, readonly) NSTimeInterval bufferedUntil;
@property (nonatomic) BOOL muted;
@property (nonatomic, readonly) NSString *engineName;      // fürs Log
// audioURL: getrennte Tonspur (DASH); nur mpv. start: Startposition (exakt), paused: nicht losspielen
- (void)openURL:(NSURL *)url audioURL:(NSURL *)audioURL start:(NSTimeInterval)start exact:(BOOL)exact paused:(BOOL)paused;
- (void)play;
- (void)pause;
- (void)seekTo:(NSTimeInterval)t exact:(BOOL)exact;
- (void)close;                    // Wiedergabe beenden (Engine bleibt nutzbar)
- (void)shutdown;                 // endgültig freigeben – VOR dem Loslassen aufrufen (mpv: Thread-Callbacks lösen)
@end

// mpv-Quelle zu einer aufgelösten URL (z. B. YouTube-DASH: video/audio/height/fps/hlsHeight/hlsFps)
void SFSetMPVSource(NSURL *forURL, NSDictionary *source);
NSDictionary *SFMPVSourceFor(NSURL *url);
BOOL SFMPVAvailable(void);        // libmpv zur Laufzeit vorhanden?
