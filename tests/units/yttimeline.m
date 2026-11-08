// sources: src/Apps/YouTube/SFYTTimeline.m src/Library/SFExtentSet.m
// flags: -Isrc/Library
// SFYTStoredRanges: a track's stored bytes in time by its segment index (Cues/sidx) - a span counts
// only when all its bytes are on disk, touching spans join, the last span needs total + duration.
#import "../../src/Apps/YouTube/SFYTTimeline.h"
#import "../../src/Library/SFExtentSet.h"
#import "SFCore.h"
BOOL SFDevMode = NO;
static int bad = 0;
static void expect(BOOL c, const char *what) { printf("%s %s\n", c ? "ok  " : "FAIL", what); if (!c) bad++; }
int main(void){ @autoreleasepool {
  // four clusters: bytes 100/300/600/1000, times 0/5/10/15 s; the file is 1500 bytes, 20 s
  NSArray *ix = @[@[@100, @0], @[@300, @5000], @[@600, @10000], @[@1000, @15000]];
  SFExtentSet *have = [SFExtentSet new];
  [have addStart:0 end:600];   // header + the first two clusters
  NSArray *r = SFYTStoredRanges(ix, 1500, 20, have);
  expect([r isEqual:@[@[@0, @10]]], "two whole clusters: 0-10 s, joined");
  [have addStart:1000 end:1400];   // the last cluster only partly
  expect([SFYTStoredRanges(ix, 1500, 20, have) isEqual:@[@[@0, @10]]], "a partly stored cluster does not count");
  [have addStart:1400 end:1500];
  expect([SFYTStoredRanges(ix, 1500, 20, have) isEqual:@[@[@0, @10], @[@15, @20]]], "the last cluster to the end of the file and video");
  expect([SFYTStoredRanges(ix, 0, 20, have) isEqual:@[@[@0, @10]]], "length unknown: the last span left out");
  expect([SFYTStoredRanges(@[], 1500, 20, have) count] == 0, "no index: nothing");
  // what the player intersects: video and audio both
  NSArray *v = @[@[@0, @10], @[@15, @20]], *a = @[@[@5, @18]];
  expect([SFRangesIntersect(v, a) isEqual:@[@[@5, @10], @[@15, @18]]], "video and audio: where both are");
  NSMutableArray *m = [NSMutableArray new];
  SFRangesAppend(m, 0, 4); SFRangesAppend(m, 4, 6); SFRangesAppend(m, 8, 9); SFRangesAppend(m, 9, 9);
  expect([m isEqual:@[@[@0, @6], @[@8, @9]]], "append joins touching ranges, skips empty ones");
  return bad ? 1 : 0;
}}
