// YouTube "Mit TV verbinden" (Lounge-API, Empfängerseite). Spezifikation und Live-
// Messungen: docs/youtube-lounge.md. Dauerhafte Kopplung über eine gespeicherte
// screenId; der Bind-Kanal läuft im Hintergrund, solange Sofa läuft.
// Long-Poll über libcurl (NSURLSession puffert den gestreamten Body auf 10.9).
#import "SFCore.h"

extern NSString *const SFLoungeRemotesDidChangeNotification;

@interface SFLounge : NSObject
+ (instancetype)shared;
- (void)start;
- (void)stop;                                        // beim Beenden (best effort)
// Neuer 12-stelliger TV-Code (≈ 5 min gültig). done auf dem Main-Thread.
- (void)fetchPairingCode:(void (^)(NSString *code, NSError *e))done;
@property (nonatomic, readonly) NSArray *remoteNames;   // verbundene Handys
@property (nonatomic, readonly) BOOL online;            // Bind-Session steht
// Privatsphäre bei mehreren Nutzern (Einstellungen, gespeichert):
@property (nonatomic) BOOL paused;              // Verbindung ruht: Kopplung bleibt, keine Befehle, nichts wird geteilt
@property (nonatomic) BOOL sharesAllPlayback;   // NO (Standard): nur vom Handy gestartete Wiedergabe ans Handy melden
- (void)forgetAllPhones;                        // Kopplung aufheben: neue screenId, Handys brauchen einen neuen Code

// Vom Handy kommende Befehle (Main-Thread). cmd: setPlaylist, play, pause, seekTo,
// next, previous, stopVideo, setVolume, setSubtitlesTrack, remoteConnected …; args = Payload (Strings).
@property (nonatomic, copy) void (^commandHandler)(NSString *cmd, NSDictionary *args);
// Liefert den aktuell sichtbaren Player (oder nil) – setzt die App.
@property (nonatomic, copy) id (^playerProvider)(void);
@end
