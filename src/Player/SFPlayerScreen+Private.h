// SFPlayerScreen - private part: ivars and methods shared by the categories
// (SFPlayerScreen.m: playback/OSD/input, SFPlayerScreen+Tracks.m: audio & subtitles).
#import "SFPlayerScreen.h"
#import "SFSettings.h"
#import "SFLayers.h"
#import "SFStore.h"
#import "SFMPVEngine.h"
#import "SFApp.h"
#import <IOKit/pwr_mgt/IOPMLib.h>
#import "SFLibrary.h"
#import "SFCurl.h"
#import "SFPower.h"
#import "SFMenuScreen.h"

@interface SFPlayerScreen () {
    SFItem *_item;
    NSArray *_queue;
    id _powerObs;
    BOOL _explicitQueue;   // phone playlist: next = next queue entry
    BOOL _openedDash;      // current attempt: separate video/audio tracks
    BOOL _subsApplied;     // preferred subtitles already applied for this item
    CALayer *_trackKey; SFLabel *_trackHint;   // OSD: "[OK] hold: info"
    NSUInteger _index;
    id<SFEngine> _engine;        // mpv (SFEngine.h)
    CALayer *_videoHost;         // hosts the video layer of the active engine
    IOPMAssertionID _assertion, _sysAssertion;
    BOOL _hasAssertion;

    CALayer *_osd;               // whole overlay
    CAGradientLayer *_topShade, *_bottomShade;
    SFLabel *_title, *_channel;
    CALayer *_barBg, *_barFill, *_barBuffer, *_barKnob;
    CALayer *_barStored;         // what of the video is on disk (SFPlayerScreen+Stored.m)
    NSArray *_storedRanges; NSTimeInterval _storedAsked;
    SFLabel *_elapsed, *_remaining, *_endsAt;
    CALayer *_pauseIcon;
    CALayer *_spinner;
    SFLabel *_message;
    CALayer *_nextCard;
    SFLabel *_nextLabel;

    NSTimer *_osdTimer;
    BOOL _osdVisible;
    NSTimeInterval _pendingSeek;    // accumulated jump (s), 0 = none
    NSTimeInterval _seekBase;       // last jump target until the player has arrived there (-1 = none)
    NSDate *_seekBaseAt;
    NSTimer *_seekTimer;
    NSTimeInterval _lastSaved;
    BOOL _ended, _failed, _closing;
    NSURL *_openURL; NSTimeInterval _openResume;
    NSURL *_servedURL;           // what mpv reads (the media proxy's URL for a source's file or playlist)
    id _resolving;               // token of the running resolve (startItem): late answers are ignored
    BOOL _holdPaused;   // "start paused" holds across reopens until the user presses play
    NSTimer *_nextTimer;
    NSInteger _nextCountdown;
    NSTimeInterval _reopenedAt;  // position of the last reopen after a broken stream (-1 = none for this item)
    NSDictionary *_carryTracks;  // reopen: titles of the audio/subtitle tracks chosen before (type -> title)
    id _sabrObs;                 // app session service lost (SFApp playbackSessionLostNotification)
    SFItem *_upNext;             // YouTube "up next" (recommendation), fetched in the background
    BOOL _upNextAsked;
    BOOL _upNextPending;         // asked, no answer yet
    BOOL _endWaitsForUpNext;     // ended: the end flow waits (kUpNextWait) for that answer
    __weak SFItem *_lastStartedItem;

    // YouTube end screen (SFPlayerScreen+Endscreen.m)
    NSArray *_esData;            // elements of the current source as received (identity: rebuild on change)
    CALayer *_esLayer;           // container over the video rect, below the OSD
    CALayer *_esScrim;           // dims the video while the tiles have focus
    NSArray *_esTiles;           // SFEndTile per valid element
    NSInteger _esFocus;          // index into _esTiles, -1 = tiles not focused (normal playback keys)
    CALayer *_esHint;            // "[▼] Empfehlungen des Kanals" / "OK: abspielen · MENU: zurück zum Video"
    BOOL _esShown;               // at least one tile visible
    BOOL _esEndDeferred;         // video ended while the tiles had focus: end flow runs on leaving them
    CGRect _esVideoRect;         // where the picture is (letterboxing respected)
    BOOL _esReady;               // the texts' fonts are loaded (measured off the main thread): tiles may be built
    NSDate *_lastVolumeAt;       // last UP/DOWN volume step (DOWN keeps adjusting the volume right after)
}
@end

// shared between SFPlayerScreen.m and its parts (+Engine, +Next, +Endscreen, +Tracks)
@interface SFPlayerScreen (Internal)
- (CGFloat)toastCenterFromBottom;
- (void)layoutForSize:(CGSize)size;
- (void)updateTitles;
- (void)showMessage:(NSString *)msg;
- (void)showSpinner:(BOOL)on;
- (void)failShowing:(NSString *)text;   // failed: text + "OK – zurück"
- (void)failWith:(NSString *)reason;    // "Wiedergabe fehlgeschlagen" + reason (nil: general sentence)
- (BOOL)awaitingPicture;
- (void)didAppear;
- (void)willDisappear;
- (void)startItem;
- (void)playURL:(NSURL *)url;
- (id)engineForDiagnostics;
- (NSTimeInterval)failurePosition;
- (BOOL)sessionSource;
- (void)streamFailed:(NSString *)why;
- (void)engineStatusChanged;
- (void)engineRateChanged;
- (void)engineBufferingChanged;
- (BOOL)nearEnd;
- (BOOL)endedEarly;
- (void)engineDidEnd;
- (void)engineInterrupted;
- (void)engineTick;
- (void)teardownPlayer;
- (void)teardown;
- (void)setAssertion:(BOOL)on;
- (NSTimeInterval)current;
// SFPlayerScreen+Stored.m
- (void)setupStoredShade;
- (void)refreshStoredRanges;   // while the bar shows: every few seconds, asked off the main thread
- (NSTimeInterval)seekOrigin;
- (SFItem *)item;
- (void)saveProgress;
- (void)tick;
- (void)updateBar;
- (void)showOSD:(BOOL)on autoHide:(BOOL)autoHide;
- (void)autoHide;
- (void)postState;
- (SFPlaybackState)playbackState;
- (NSArray *)queue;
- (NSUInteger)queueIndex;
- (void)updatePauseState;
- (void)togglePause;
- (void)leaveEnd;
- (void)seekBy:(NSTimeInterval)delta;
- (void)commitSeek;
- (NSUInteger)nextQueueIndex;
- (SFItem *)nextItem;
- (BOOL)wantsUpNext;
- (void)askUpNext;
- (void)forgetUpNext;
- (void)didEnd:(NSNotification *)n;
- (void)finishEnd;
- (void)showNextCard:(SFItem *)next;
- (void)nextTick:(NSTimer *)t;
- (void)playItem:(SFItem *)item;
- (BOOL)hasExplicitQueue;
- (void)showInfo;
- (void)playNext;
- (BOOL)handleKey:(SFKey)key;
@end

@interface SFPlayerScreen (Engine) <SFEngineDelegate>
@end

@interface SFPlayerScreen (Endscreen)
- (void)esUpdate;                     // show/hide tiles for the current time (tick, seek, layout, end)
- (void)esReset;                      // new item: forget the tiles
- (void)esLayout;                     // size changed: re-place the tiles over the video rect
- (BOOL)esEngaged;                    // tiles have focus
- (BOOL)esHandleKey:(SFKey)key;       // YES = consumed by the end screen
@end

@interface SFPlayerScreen (Tracks)
- (BOOL)tracksAvailable;
- (NSArray *)trackChoices:(NSString *)type;      // title, selected, apply, lang (+ kind)
- (NSString *)currentChoice:(NSArray *)choices;
- (void)showChoices:(NSArray *)choices type:(NSString *)type title:(NSString *)title on:(SFNavigator *)nav;
- (BOOL)canSwitchToStream;                       // downloaded file with an online counterpart
- (void)applyPreferredSubtitles;
- (NSDictionary *)chosenTracks;                  // type -> title of the selected choice (nil: tracks not known yet)
- (void)restoreTracks:(NSDictionary *)tracks;
- (NSDictionary *)choiceTitled:(NSString *)title in:(NSArray *)choices;    // select those choices again (a reopened stream)
- (void)switchToStream;
@end
