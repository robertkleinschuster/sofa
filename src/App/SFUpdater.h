// Automatische Updates aus GitHub-Releases (nur Release-Bundle, siehe SFRuntime).
//
// Ablauf: GitHub-API fragen -> neuere Version? -> Sofa-<v>.dmg + .sha256 laden, prüfen ->
// Bundle aus der DMG nach <App>.update kopieren und prüfen -> sobald Sofa ruht (keine Wiedergabe,
// 15 min keine Taste) in <App>.staged umbenennen. Den Tausch macht der Helper (SofaRemote) wie bei
// jedem Update: Sofa sichert Zustand, Tausch, Neustart, Fortsetzen.
#import <Foundation/Foundation.h>

@class SFNavigator;

@interface SFUpdater : NSObject
+ (instancetype)shared;
// Automatik (5 min nach Start, dann alle 6 h), wenn „Automatisch aktualisieren“ an ist:
// suchen, laden, prüfen, installieren sobald Sofa ruht.
- (void)startWithNavigator:(SFNavigator *)nav;
// Nur suchen (Einstellungen): danach latestVersion/updateAvailable; message = Ergebnis für die Anzeige.
- (void)check:(void (^)(NSString *message))done;
// Gefundenes Update laden, prüfen und sofort installieren (Sofa sichert Zustand, startet neu).
- (void)install:(void (^)(NSString *message))progress;
@property (nonatomic, readonly) BOOL available;          // Updates möglich (Release-Bundle, Ordner beschreibbar)
@property (nonatomic, readonly) NSString *installedVersion;
@property (nonatomic, readonly) NSString *latestVersion; // nil = noch nicht gesucht
@property (nonatomic, readonly) BOOL updateAvailable;    // latestVersion > installedVersion
@property (nonatomic, readonly) NSDate *lastCheck;
@property (nonatomic, readonly) NSString *releaseNotes;   // Text des GitHub-Releases (Markdown)
@property (nonatomic, readonly) BOOL busy;
@end
