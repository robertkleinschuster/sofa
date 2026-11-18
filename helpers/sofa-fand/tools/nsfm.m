// nsfm PATH: create PATH (with intermediates) via NSFileManager; crash canary for crashcheck.sh
#import <Foundation/Foundation.h>
int main(int argc, char **argv) { @autoreleasepool {
  if (argc < 2) return 2;
  NSError *e = nil;
  BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithUTF8String:argv[1]] withIntermediateDirectories:YES attributes:nil error:&e];
  return ok ? 0 : 1; } }
