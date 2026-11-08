// SFPlayerBar - what the player's timeline says (left: elapsed, right: remaining, "Endet um").
// Live is the item's kind, never a guess: a video whose length the player does not know yet
// (still loading) is no live stream - it shows what is known and no knob until the length arrives.
#import <Foundation/Foundation.h>
#import "SFModel.h"

typedef NS_ENUM(NSInteger, SFBarMode) {
    SFBarLive,       // a live stream: "LIVE", the bar full, no knob
    SFBarLoading,    // a video, its length not known yet: the bar empty, no knob, no remaining time
    SFBarVideo,      // a video of known length: position, knob, remaining, ends at
};

SFBarMode SFBarModeFor(SFItemKind kind, NSTimeInterval duration);
// the left label: "LIVE", the position ("0:00" at the start), or while loading the position once
// playback has one (empty before)
NSString *SFBarElapsedText(SFBarMode mode, NSTimeInterval shown);
