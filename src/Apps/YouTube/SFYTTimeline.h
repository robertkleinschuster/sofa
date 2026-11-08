// SFYTTimeline - a YouTube track's stored bytes in time (docs/media-store.md 5c): its segment index
// (WebM Cues / MP4 sidx, from the engine: @[@[byte offset, ms]] sorted) splits the file into spans;
// a span whose bytes are all on disk is stored for its time. Exact - no proportional guess.
#import <Foundation/Foundation.h>
@class SFExtentSet;

// The track's stored time ranges @[@[start s, end s]]; the last span ends at `total` bytes and
// `duration` s (0: not known - the last span is left out)
NSArray *SFYTStoredRanges(NSArray *index, long long total, double duration, SFExtentSet *have);
