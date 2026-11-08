// sources: src/Library/SFMP4Index.m
// SFMP4Index on real files (ffmpeg, moov at the start and at the end): every audio/video track's
// chunks span the media without gaps, a file wholly there is stored end to end, missing bytes leave a
// gap where their chunks play, no moov on disk = no index.
#import "../../src/Library/SFMP4Index.h"
#import "SFCore.h"
BOOL SFDevMode = NO;
static int bad = 0;
static void expect(BOOL c, const char *what) { printf("%s %s\n", c ? "ok  " : "FAIL", what); if (!c) bad++; }
static NSData *Make(NSString *path, BOOL faststart) {
    NSMutableArray *a = [@[@"-hide_banner", @"-loglevel", @"error", @"-y", @"-f", @"lavfi", @"-i", @"testsrc=size=320x180:rate=25", @"-f", @"lavfi",
                           @"-i", @"sine", @"-t", @"10", @"-c:v", @"libx264", @"-preset", @"ultrafast", @"-c:a", @"aac"] mutableCopy];
    if (faststart) [a addObjectsFromArray:@[@"-movflags", @"+faststart"]];
    [a addObject:path];
    NSTask *t = [NSTask launchedTaskWithLaunchPath:@"/opt/local/bin/ffmpeg" arguments:a];
    [t waitUntilExit];
    return [NSData dataWithContentsOfFile:path];
}
static double Covered(NSArray *r) { double n = 0; for (NSArray *x in r) n += [x[1] doubleValue] - [x[0] doubleValue]; return n; }
int main(void){ @autoreleasepool {
  NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"mp4index-%d", getpid()]];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  for (NSNumber *fs in @[@YES, @NO]) {
    NSData *f = Make([dir stringByAppendingPathComponent:fs.boolValue ? @"fast.mp4" : @"tail.mp4"], fs.boolValue);
    printf("-- moov %s (%lu bytes)\n", fs.boolValue ? "first" : "last", (unsigned long)f.length);
    NSData *(^all)(long long, NSUInteger) = ^NSData *(long long off, NSUInteger len) {
      return off + (long long)len <= (long long)f.length ? [f subdataWithRange:NSMakeRange((NSUInteger)off, len)] : nil; };
    SFMP4Index *ix = [SFMP4Index indexWithLength:(long long)f.length read:all];
    expect(ix.tracks.count == 2, "two tracks (video, audio)");
    BOOL gapless = YES;
    for (NSArray *chunks in ix.tracks)
      for (NSUInteger i = 1; i < chunks.count; i++) if (fabs([chunks[i][2] doubleValue] - [chunks[i - 1][3] doubleValue]) > 1e-9) gapless = NO;
    expect(gapless, "each track's chunks follow each other in time");
    NSArray *whole = [ix storedRanges:^BOOL(long long a, long long b) { return YES; }];
    expect(whole.count == 1 && [whole[0][0] doubleValue] < 0.1 && fabs([whole[0][1] doubleValue] - 10) < 0.1, "all there: one range over the 10 s");
    // the middle third of the file missing: a gap in time, the rest stays
    long long g0 = (long long)f.length / 3, g1 = 2 * (long long)f.length / 3;
    NSArray *part = [ix storedRanges:^BOOL(long long a, long long b) { return b <= g0 || a >= g1; }];
    expect(part.count >= 1 && Covered(part) > 2 && Covered(part) < 9, "missing bytes: a gap where they play");
    NSData *(^none)(long long, NSUInteger) = ^NSData *(long long off, NSUInteger len) { return nil; };
    expect([SFMP4Index indexWithLength:(long long)f.length read:none] == nil, "nothing on disk: no index");
  }
  [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
  return bad ? 1 : 0;
}}
