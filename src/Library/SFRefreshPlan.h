// When a followed show/channel is looked at again (SFFollows): like a person who knows its rhythm,
// not a crawler - a channel that uploads weekly is not checked every 30 minutes, checks are spread
// (each at its own time, with some variation, never two right after another) and rarer at night.
// Pure functions (no clock, no randomness of their own): `now` and `r` (a random number in [0,1))
// come from the caller, so the plan is testable (tests/units/refreshplan.m).
#import <Foundation/Foundation.h>

extern const NSTimeInterval SFRefreshMin, SFRefreshMax;   // 2 h ... 24 h
extern const NSTimeInterval SFRefreshGapMin;              // between any two checks: 20 s (+ up to 20 s)

// interval from the show's upload dates (any order): a quarter of the median gap between its
// newest uploads, within [SFRefreshMin, SFRefreshMax]; fewer than 3 dates: 2 h
NSTimeInterval SFRefreshInterval(NSArray *uploadDates);
// next check after one at `checked`: the interval, +/-20 % (r), doubled when it falls into the night
// (0-6 h local time in `tz`)
NSDate *SFRefreshNextDue(NSArray *uploadDates, NSDate *checked, double r, NSTimeZone *tz);
// pause before the next check of any follow
NSTimeInterval SFRefreshGap(double r);
// while Sofa rests or runs warm (SFRest), follows come in batches: the next batch after `now` -
// about every 2 h by day, 4-6 h by night (23-6 h local time in `tz`), +/-20 % (r); skipNight
// (the apps' services end at night): not before 6:00 (+ up to 30 min, r)
NSDate *SFRefreshBatchAfter(NSDate *now, double r, BOOL skipNight, NSTimeZone *tz);
// One planning step of SFFollows: `when` = the plain plan for the next follow (due, after the gap).
// Batched (resting or warm): outside a batch the plan waits for *batchAt (drawn once, kept until that
// batch has run); inside one (*inBatch, set by the caller when a batch's first check starts) every
// follow due by `now` goes on, the first not yet due ends it and draws the next *batchAt. Not
// batched: the plain plan, the state cleared.
NSDate *SFRefreshBatchStep(NSDate *when, NSDate *due, NSDate *now, BOOL batched, BOOL *inBatch, NSDate **batchAt,
                           double r, BOOL skipNight, NSTimeZone *tz);
