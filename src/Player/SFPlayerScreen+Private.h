// SFPlayerScreen – privater Teil: Ivars und Methoden, die die Kategorien gemeinsam nutzen
// (SFPlayerScreen.m: Wiedergabe/OSD/Eingabe, SFPlayerScreen+Tracks.m: Ton & Untertitel).
#import "SFPlayerScreen.h"
#import "SFSettings.h"
#import "SFLayers.h"
#import "SFStore.h"
#import "SFAVEngine.h"
#import "SFMPVEngine.h"
#import "SFYTResolver.h"
#import "SFYouTube.h"
#import <IOKit/pwr_mgt/IOPMLib.h>
#import "SFLibrary.h"
#import "SFCurl.h"
#import "SFPower.h"
#import "SFMenuScreen.h"

@interface SFPlayerScreen () <SFEngineDelegate> {
    SFItem *_item;
    NSArray *_queue;
    id _powerObs;
    BOOL _explicitQueue;   // Handy-Playlist: nächster = nächster Queue-Eintrag
    NSURL *_dashFailedURL; // DASH-Streams dieser Quelle abgelehnt (YouTube 403) -> mpv mit dem HLS-Stream
    BOOL _openedDash;      // aktueller Versuch: mpv mit getrennten DASH-Streams
    BOOL _subsApplied;     // bevorzugte Untertitel für diesen Inhalt schon angewandt
    CALayer *_trackKey; SFLabel *_trackHint;   // OSD: "[OK] halten: Info"
    NSUInteger _index;
    id<SFEngine> _engine;        // AVFoundation oder mpv (SFEngine.h)
    CALayer *_videoHost;         // trägt die Video-Ebene der aktiven Engine
    IOPMAssertionID _assertion, _sysAssertion;
    BOOL _hasAssertion;

    CALayer *_osd;               // gesamte Einblendung
    CAGradientLayer *_topShade, *_bottomShade;
    SFLabel *_title, *_channel;
    CALayer *_barBg, *_barFill, *_barBuffer, *_barKnob;
    SFLabel *_elapsed, *_remaining, *_endsAt;
    CALayer *_pauseIcon;
    CALayer *_spinner;
    SFLabel *_message;
    CALayer *_nextCard;
    SFLabel *_nextLabel;

    NSTimer *_osdTimer;
    BOOL _osdVisible;
    NSTimeInterval _pendingSeek;    // kumulierter Sprung (s), 0 = keiner
    NSTimeInterval _seekBase;       // letztes Sprungziel, bis der Player dort angekommen ist (-1 = keins)
    NSDate *_seekBaseAt;
    NSTimer *_seekTimer;
    NSTimeInterval _lastSaved;
    BOOL _ended, _failed, _closing;
    NSURL *_openURL; NSDate *_openAt; NSInteger _openTries; NSTimeInterval _openResume;
    BOOL _holdPaused;   // „pausiert starten“ gilt über Wiederholungsversuche/Ausweich-Streams hinweg, bis der User Play drückt   // Retry bei sporadischem HLS-Öffnungsfehler
    NSTimer *_nextTimer;
    NSInteger _nextCountdown;
    NSURL *_mpvFailedURL;        // mpv scheiterte an dieser URL -> AVFoundation versuchen
    BOOL _reresolved;            // YouTube: Streams abgelehnt -> einmal frisch auflösen
    SFItem *_upNext;             // YouTube „Als Nächstes“ (Empfehlung), im Hintergrund geholt
    BOOL _upNextAsked;
    __weak SFItem *_lastStartedItem;
}
- (NSTimeInterval)currentTime;
- (void)togglePause;
- (SFItem *)nextItem;                 // what autoplay plays next (queue, playlist, episode, recommendation)
- (void)playItem:(SFItem *)item;      // play another item in this player, like autoplay
- (BOOL)hasExplicitQueue;             // queue from the phone: next = next queue entry
- (void)showInfo;                     // info panel (OK hold)
@end

@interface SFPlayerScreen (Tracks)
- (BOOL)tracksAvailable;
- (NSArray *)trackChoices:(NSString *)type;      // title, selected, apply, lang (+ kind)
- (NSString *)currentChoice:(NSArray *)choices;
- (void)showChoices:(NSArray *)choices type:(NSString *)type title:(NSString *)title on:(SFNavigator *)nav;
- (BOOL)canSwitchToStream;                       // downloaded file with an online counterpart
- (void)applyPreferredSubtitles;
- (void)switchToStream;
@end
