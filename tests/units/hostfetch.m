// sources: src/Core/SFHostFetch.m
// SFHostFetch: a source's hosts go to its registered client - exact names and ".suffix" entries,
// case-insensitive; every other host (and a look-alike) stays native.
#import "SFHostFetch.h"
BOOL SFDevMode = NO;   // main.m's, for SFCore.m
static int bad = 0;
static void expect(BOOL c, const char *what) { printf("%s %s\n", c ? "ok  " : "FAIL", what); if (!c) bad++; }
static SFHostFetcher at(NSString *u) { return SFHostFetcherFor([NSURL URLWithString:u]); }
int main(void) { @autoreleasepool {
    expect(at(@"https://i.ytimg.com/vi/x/hqdefault.jpg") == nil, "nothing registered: native");
    SFHostFetcher yt = ^(NSURL *u, SFHostFetchDone d) { d(nil, 0); };
    SFHostFetcher other = ^(NSURL *u, SFHostFetchDone d) { d(nil, 1); };
    SFRegisterHostFetcher(@[@".ytimg.com", @"yt3.googleusercontent.com"], yt);
    SFRegisterHostFetcher(@[@"img.example.org"], other);
    expect(at(@"https://i.ytimg.com/vi/x/hqdefault.jpg") == yt, "suffix entry");
    expect(at(@"https://I9.YTIMG.com/x.jpg") == yt, "case-insensitive");
    expect(at(@"https://yt3.googleusercontent.com/a=s88") == yt, "exact entry");
    expect(at(@"https://lh3.googleusercontent.com/a") == nil, "exact entry is not a suffix");
    expect(at(@"https://evilytimg.com/x.jpg") == nil, "look-alike host stays native");
    expect(at(@"https://img.example.org/p.png") == other, "each source its own client");
    expect(at(@"https://www.ardmediathek.de/x") == nil, "other hosts native");
    expect(at(@"/Users/x/pic.jpg") == nil, "a file path is no host");
    return bad ? 1 : 0;
} }
