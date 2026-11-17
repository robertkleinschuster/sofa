// SFYTNight - "Nachts ganz ruhen": when the engine ends for the night and when it comes back
// (SFYTEngine+Rest). Pure: the caller knows the facts, this decides.
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SFYTNightAction) { SFYTNightNone, SFYTNightStop, SFYTNightWake };

// want: resting, the setting on, night, no download filling. stopped: ended for this night.
// ready: the browser runs again anyway (a use started it). restoppedTonight: it was ended a second
// time this night already - not again (each start is a new page and attestation: no cycle).
// over: the night is over or the setting was switched off.
SFYTNightAction SFYTNightDecide(BOOL want, BOOL stopped, BOOL ready, BOOL restoppedTonight, BOOL over);
// the night a time belongs to (its evening's date, 23-6 h), to remember a second stop per night
NSString *SFYTNightKey(NSDate *at, NSTimeZone *tz);
