// sources: src/Player/SFCPUMeter.m
// flags: -Isrc/Player
// SFCPUMeter: CPU over wall time of the ticks that counted - the CPU a fixed workload burns is
// counted, sleeping costs ~nothing, a stretch not counted (paused, waiting) stays out. Load-proof:
// the workload is CPU time (clock()), not wall time - under test-all a wall-timed loop got 6 %.
#import "SFCPUMeter.h"
#import "SFCore.h"
BOOL SFDevMode = NO;
static int bad = 0;
static void expect(BOOL c, const char *what) { printf("%s %s\n", c ? "ok  " : "FAIL", what); if (!c) bad++; }
static void burn(double cpuSeconds) { clock_t c0 = clock(); volatile double x = 0; while ((double)(clock() - c0) / CLOCKS_PER_SEC < cpuSeconds) x += 1; }
int main(void){ @autoreleasepool {
  SFCPUMeter *busy = [SFCPUMeter new];
  [busy tick:YES]; burn(0.1); [busy tick:YES];
  double counted = busy.percentOfCore / 100 * busy.seconds;
  printf("     busy: %.0f%% over %.2f s = %.3f CPU s\n", busy.percentOfCore, busy.seconds, counted);
  expect(counted >= 0.09, "0.1 CPU s of work: counted, however long the wall clock took");
  SFCPUMeter *idle = [SFCPUMeter new];
  [idle tick:YES]; usleep(300000); [idle tick:YES];
  printf("     idle: %.0f%%\n", idle.percentOfCore);
  expect(idle.percentOfCore / 100 * idle.seconds < 0.03, "sleeping: next to no CPU");
  SFCPUMeter *paused = [SFCPUMeter new];
  [paused tick:YES]; burn(0.1); [paused tick:NO]; usleep(200000); [paused tick:YES];
  expect(paused.percentOfCore / 100 * paused.seconds < 0.03 && paused.seconds >= 0.19, "a stretch not counted stays out (only the sleep counted)");
  expect([SFCPUMeter new].seconds == 0 && [SFCPUMeter new].percentOfCore == 0, "nothing counted: 0");
  return bad ? 1 : 0;
}}
