// Abspiel-Engines hinter SFPlayerScreen (docs/codecs-research.md):
//  - SFMPVEngine: libmpv (VP9/AV1/Opus, DASH, HLS, H.264 in Software) – Standard seit 2026-11-04;
//                 schwach gelinkt (optional).
//  - SFAVEngine:  AVFoundation (Hardware-H.264, HLS) – Ausweg, wenn mpv scheitert, und per
//                 Notschalter SFPreferAVFoundation (defaults) die alte Wahl.
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
@optional
// Ton-/Untertitelspuren (nur mpv). type = @"audio" | @"sub". Einträge: id (NSNumber), lang, title,
// selected (BOOL), url (nur externe Spuren).
- (NSArray *)tracksOfType:(NSString *)type;
- (void)selectTrack:(NSString *)type trackID:(NSInteger)tid;   // 0 = aus
// Externe Spur (z.B. YouTube-Untertitel als WebVTT, andere Sprachfassung) laden und auswählen;
// war dieselbe URL schon geladen, wird nur ausgewählt.
- (void)addTrack:(NSString *)type url:(NSURL *)url title:(NSString *)title lang:(NSString *)lang;
@end

// mpv-Quelle zu einer aufgelösten URL (z. B. YouTube-DASH: video/audio/height/fps/hlsHeight/hlsFps)
void SFSetMPVSource(NSURL *forURL, NSDictionary *source);
NSDictionary *SFMPVSourceFor(NSURL *url);
BOOL SFMPVAvailable(void);        // libmpv zur Laufzeit vorhanden?
