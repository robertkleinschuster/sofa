// sources: src/Player/SFCPUMeter.m
// flags: -Isrc/Player
// SFCPUMeter: CPU over wall time of the ticks that counted - busy work reads high, sleeping low, a
// stretch not counted (paused, waiting) stays out. Bounds are generous: test-all's load stretches
// wall time while the process waits for a core.
#import "SFCPUMeter.h"
#import "SFCore.h"
BOOL SFDevMode = NO;
static int bad = 0;
static void expect(BOOL c, const char *what) { printf("%s %s\n", c ? "ok  " : "FAIL", what); if (!c) bad++; }
static void spin(double s) { double t0 = [NSDate timeIntervalSinceReferenceDate]; volatile double x = 0; while ([NSDate timeIntervalSinceReferenceDate] - t0 < s) x += 1; }
int main(void){ @autoreleasepool {
  SFCPUMeter *busy = [SFCPUMeter new];
  [busy tick:YES]; spin(0.3); [busy tick:YES];
  printf("     busy: %.0f%% over %.2f s\n", busy.percentOfCore, busy.seconds);
  expect(busy.percentOfCore > 30 && busy.seconds > 0.25, "busy work: high");
  SFCPUMeter *idle = [SFCPUMeter new];
  [idle tick:YES]; usleep(300000); [idle tick:YES];
  printf("     idle: %.0f%%\n", idle.percentOfCore);
  expect(idle.percentOfCore < 30, "sleeping: low");
  SFCPUMeter *paused = [SFCPUMeter new];
  [paused tick:YES]; spin(0.2); [paused tick:NO]; usleep(200000); [paused tick:YES];
  expect(paused.seconds > 0.15 && paused.seconds < 0.3 && paused.percentOfCore < 30, "a stretch not counted stays out (only the sleep counted)");
  expect([SFCPUMeter new].seconds == 0 && [SFCPUMeter new].percentOfCore == 0, "nothing counted: 0");
  return bad ? 1 : 0;
}}
