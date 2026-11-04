// SFPlayerScreen - private part: ivars and methods shared by the categories
// (SFPlayerScreen.m: playback/OSD/input, SFPlayerScreen+Tracks.m: audio & subtitles).
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
    BOOL _explicitQueue;   // phone playlist: next = next queue entry
    NSURL *_dashFailedURL; // DASH streams of this source rejected (YouTube 403) -> mpv with the HLS stream
    BOOL _openedDash;      // current attempt: mpv with separate DASH streams
    BOOL _subsApplied;     // preferred subtitles already applied for this item
    CALayer *_trackKey; SFLabel *_trackHint;   // OSD: "[OK] hold: info"
    NSUInteger _index;
    id<SFEngine> _engine;        // AVFoundation or mpv (SFEngine.h)
    CALayer *_videoHost;         // hosts the video layer of the active engine
    IOPMAssertionID _assertion, _sysAssertion;
    BOOL _hasAssertion;

    CALayer *_osd;               // whole overlay
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
    NSTimeInterval _pendingSeek;    // accumulated jump (s), 0 = none
    NSTimeInterval _seekBase;       // last jump target until the player has arrived there (-1 = none)
    NSDate *_seekBaseAt;
    NSTimer *_seekTimer;
    NSTimeInterval _lastSaved;
    BOOL _ended, _failed, _closing;
    NSURL *_openURL; NSDate *_openAt; NSInteger _openTries; NSTimeInterval _openResume;
    BOOL _holdPaused;   // "start paused" holds across retries/fallback streams until the user presses play   // retry on sporadic HLS open errors
    NSTimer *_nextTimer;
    NSInteger _nextCountdown;
    NSURL *_mpvFailedURL;        // mpv failed on this URL -> try AVFoundation
    BOOL _reresolved;            // YouTube: streams rejected -> resolve afresh once
    SFItem *_upNext;             // YouTube "up next" (recommendation), fetched in the background
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
