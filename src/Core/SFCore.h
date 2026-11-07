// Sofa — 10-foot media center for macOS 10.9 (Apple Remote, mpv).
// Shared basics: input keys, layout scaling, logging, helpers.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

typedef NS_ENUM(NSInteger, SFKey) {
    SFKeyUp, SFKeyDown, SFKeyLeft, SFKeyRight,
    SFKeySelect, SFKeyMenu, SFKeyPlayPause,
    SFKeySelectHold, SFKeyMenuHold,
    SFKeyNext, SFKeyPrev,      // seeking (remote hold left/right, keyboard ,/.)
    SFKeyUpHold, SFKeyDownHold,
};
// Names of the keys (log, dev FIFO "key <name>"): "up", "selecthold", ...; unknown -> nil / -1
NSString *SFKeyName(SFKey key);
SFKey SFKeyFromName(NSString *name);

// All layout measures are given in "design units" of a 1920x1080 canvas
// and are scaled to the real screen height with SFScale.
extern CGFloat SFScale;
static inline CGFloat U(CGFloat v) { return round(v * SFScale); }

void SFLogFlush(void);   // wait until queued log lines are written (before _exit)
void SFLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
// The log: ~/Library/Logs/Sofa.log; a dev instance ~/Library/Logs/Sofa-dev-<instance>.log, or
// <SOFA_DATA_DIR>/sofa.log (tests: gone with their temporary directory). Fixed once SFLog ran.
NSString *SFLogPath(void);

static inline void SFMain(dispatch_block_t b) {
    if ([NSThread isMainThread]) b(); else dispatch_async(dispatch_get_main_queue(), b);
}
static inline void SFBackground(dispatch_block_t b) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), b);
}

NSColor *SFHex(uint32_t rgb);
NSColor *SFHexA(uint32_t rgb, CGFloat a);
NSString *SFFormatDuration(NSTimeInterval secs);   // 1:02:03 / 4:05
// ISO 8601 from source APIs: "2026-11-05", "2026-11-05T05:13:00Z", "…T18:25:00.000000+00:00",
// "…T01:00:00.000+01:00", "…T23:45:10+0100". The offset is honoured; a time without one is UTC;
// a date without a time is local midnight (a calendar day). nil when unparseable. Thread-safe.
NSDate *SFDateFromISO8601(NSString *s);
NSString *SFFormatClock(NSDate *d);                // "18:05" (main thread)
NSString *SFFormatDateShort(NSDate *d);            // "Heute", "Gestern", "12. Okt."
// Tile subtitles: joins the non-empty parts with " · " (nil/"" parts are skipped, so a missing
// channel or date never leaves a dangling separator). Usage: SFDotJoin(channel, date, state)
// Variadic call: ARC keeps every argument (also temporaries) alive for the whole call; the
// sizeof literal only counts the arguments and is never evaluated.
NSString *SFDotJoinN(NSUInteger n, ...);
#define SFDotJoin(...) SFDotJoinN(sizeof((NSString *__unsafe_unretained const[]){__VA_ARGS__}) / sizeof(NSString *), __VA_ARGS__)
// Fair merge of several ranked lists: the first of each, then the second of each, … up to `max`;
// an element whose key was seen before (or is nil) is skipped. E.g. Home rows mixed from all apps.
NSArray *SFInterleave(NSArray *lists, NSUInteger max, id (^key)(id element));
// JSON text <-> objects (stored items, feeds): nil when not representable / not parseable
NSString *SFJSONString(id obj);
id SFJSONParse(NSString *text);
// Where Sofa keeps its state (database, the YouTube engine's browser profile, a dev instance's downloads). The real app:
// ~/Library/Application Support/Sofa. A dev instance never shares it - isolated by construction,
// not by per-file checks: Application Support/Sofa-dev/<instance>, or $SOFA_DATA_DIR (tests: a
// fresh temporary directory per run). Set once at launch, before anything is stored.
void SFSetDevInstance(NSString *instance);
NSString *SFDevInstanceName(void);   // "view" by default; nil in the real app
// dev: files of this instance that live beside the shared ones (log, dev FIFO): the data
// directory when SOFA_DATA_DIR chose it, else nil (then ~/Library/Logs, the shared cache)
NSString *SFDevPrivateDir(void);
NSString *SFAppSupportDir(void);
// Caches: the real app ~/Library/Caches/Sofa, a dev instance <data dir>/Caches (images, the
// updater's work dir - nothing a test does reaches the real app's).
NSString *SFCacheDir(void);
// Shared by every instance on this machine, on purpose: what must hold for all of them (the
// YouTube bot-check pause: one IP) and the dev control pipes. ~/Library/Caches/Sofa.
NSString *SFSharedCacheDir(void);

// Animation helper: animate all changes in the block with a uniform curve.
void SFAnimate(CFTimeInterval dur, dispatch_block_t changes);
void SFNoAnimate(dispatch_block_t changes);

extern BOOL SFDevMode;   // invisible development mode (main.m)
// Test knobs: environment variable NAME, honoured in dev instances only (never in the real app).
NSString *SFDevEnv(NSString *name);
// a duration knob: NAME in seconds when set (> 0) in a dev instance, otherwise the default
NSTimeInterval SFDevSeconds(NSString *name, NSTimeInterval dflt);

// Dev: render the layer tree into a context; video layers are replaced by their current frame.
void SFRenderLayerTree(CALayer *root, CGContextRef ctx);

// Dev test: SOFA_OFFLINE=1 makes all network requests fail (dev instances only)
BOOL SFSimulatedOffline(void);
