// sources: helper/SRSupervisor.m
// SRSupervisor: relaunch a crashed Sofa after the grace time, never after a planned exit, at most
// 3 times in 10 min (crash at launch), again once it ran normally.
#import "../../helper/SRSupervisor.h"
#import "SFCore.h"
BOOL SFDevMode = NO;
static int bad = 0;
static void expect(BOOL c, const char *what) { printf("%s %s\n", c ? "ok  " : "FAIL", what); if (!c) bad++; }
int main(void){ @autoreleasepool {
  SRSupervisor *s = [SRSupervisor new];
  NSDate *t0 = [NSDate dateWithTimeIntervalSince1970:1000000];
  NSDate *(^at)(double) = ^(double x) { return [t0 dateByAddingTimeInterval:x]; };
  expect(![s shouldRelaunchAt:at(0) running:YES markerLeft:YES], "running: nothing");
  expect(![s shouldRelaunchAt:at(3) running:NO markerLeft:NO], "planned exit (no marker): nothing");
  expect(![s shouldRelaunchAt:at(60) running:NO markerLeft:NO], "still nothing much later");
  expect(![s shouldRelaunchAt:at(100) running:NO markerLeft:YES], "crash: waits for the grace time");
  expect(![s shouldRelaunchAt:at(106) running:NO markerLeft:YES], "6 s: launchd may be on it");
  expect(![s shouldRelaunchAt:at(109) running:YES markerLeft:YES], "launchd relaunched it: nothing");
  expect(![s shouldRelaunchAt:at(200) running:NO markerLeft:YES], "crash again: grace starts anew");
  expect([s shouldRelaunchAt:at(210) running:NO markerLeft:YES], "relaunch after 10 s");
  // crashing right at launch: two more relaunches, then it gives up
  expect(![s shouldRelaunchAt:at(213) running:NO markerLeft:YES], "no burst: a new grace period");
  expect([s shouldRelaunchAt:at(223) running:NO markerLeft:YES], "2nd relaunch");
  expect(![s shouldRelaunchAt:at(226) running:NO markerLeft:YES], "grace again");
  expect([s shouldRelaunchAt:at(236) running:NO markerLeft:YES], "3rd relaunch");
  expect(![s shouldRelaunchAt:at(239) running:NO markerLeft:YES], "grace again");
  expect(![s shouldRelaunchAt:at(250) running:NO markerLeft:YES] && s.gaveUp, "4th within 10 min: gives up");
  expect(![s shouldRelaunchAt:at(900) running:NO markerLeft:YES], "given up stays given up while it never ran");
  expect(![s shouldRelaunchAt:at(901) running:YES markerLeft:YES] && !s.gaveUp, "a normal run resets it");
  expect(![s shouldRelaunchAt:at(1000) running:NO markerLeft:YES], "later crash: grace");
  expect([s shouldRelaunchAt:at(1011) running:NO markerLeft:YES], "relaunched again (old ones out of the window)");
  printf(bad ? "FAILED\n" : "all ok\n"); return bad;
}}
