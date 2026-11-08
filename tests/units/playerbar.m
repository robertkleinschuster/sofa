// sources: src/Player/SFPlayerBar.m
// flags: -Isrc/Player
// SFPlayerBar: live is the item's kind - a video still loading (length unknown) never says "LIVE"
// (user 2026-11-08: the player showed "LIVE" bottom left while a video loaded).
#import "SFPlayerBar.h"
#import "SFCore.h"
BOOL SFDevMode = NO;
static int bad = 0;
static void expect(BOOL c, const char *what) { printf("%s %s\n", c ? "ok  " : "FAIL", what); if (!c) bad++; }
int main(void){ @autoreleasepool {
  expect(SFBarModeFor(SFItemVideo, 0) == SFBarLoading, "a video without a length yet is loading, not live");
  expect(SFBarModeFor(SFItemVideo, NAN) == SFBarLoading, "an unknown (NaN) length: loading");
  expect(SFBarModeFor(SFItemVideo, 959) == SFBarVideo, "a video of known length");
  expect(SFBarModeFor(SFItemLive, 0) == SFBarLive, "a live stream");
  expect(SFBarModeFor(SFItemLive, 7200) == SFBarLive, "a live stream with a DVR window stays live");
  expect([SFBarElapsedText(SFBarLoading, 0) isEqual:@""], "loading: no time on the left");
  expect(![SFBarElapsedText(SFBarLoading, 0) isEqual:@"LIVE"], "loading never says LIVE");
  expect([SFBarElapsedText(SFBarLoading, 65) isEqual:@"1:05"], "loading but playing: the position");
  expect([SFBarElapsedText(SFBarVideo, 0.4) isEqual:@"0:00"], "a video at its start: 0:00");
  expect([SFBarElapsedText(SFBarVideo, 3723) isEqual:@"1:02:03"], "a video: its position");
  expect([SFBarElapsedText(SFBarLive, 30) isEqual:@"LIVE"], "live: LIVE");
  return bad ? 1 : 0;
}}
