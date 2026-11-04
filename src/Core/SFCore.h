// Sofa — 10-foot media center for macOS 10.9 (Apple Remote, AVFoundation).
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

// All layout measures are given in "design units" of a 1920x1080 canvas
// and are scaled to the real screen height with SFScale.
extern CGFloat SFScale;
static inline CGFloat U(CGFloat v) { return round(v * SFScale); }

void SFLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
extern NSString *SFLogFileName;   // "Sofa.log"; dev instances: "Sofa-dev-<instance>.log"

static inline void SFMain(dispatch_block_t b) {
    if ([NSThread isMainThread]) b(); else dispatch_async(dispatch_get_main_queue(), b);
}
static inline void SFBackground(dispatch_block_t b) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), b);
}

NSColor *SFHex(uint32_t rgb);
NSColor *SFHexA(uint32_t rgb, CGFloat a);
NSString *SFFormatDuration(NSTimeInterval secs);   // 1:02:03 / 4:05
NSString *SFFormatDateShort(NSDate *d);            // "Heute", "Gestern", "12. Okt."
NSString *SFAppSupportDir(void);                   // ~/Library/Application Support/Sofa
NSString *SFCacheDir(void);                        // ~/Library/Caches/Sofa

// Animation helper: animate all changes in the block with a uniform curve.
void SFAnimate(CFTimeInterval dur, dispatch_block_t changes);
void SFNoAnimate(dispatch_block_t changes);

extern BOOL SFDevMode;   // invisible development mode (main.m)

// Dev: render the layer tree into a context (model layers, AVPlayerLayer left out —
// presentationLayer copies of the AVPlayerLayer crash on release on 10.9).
void SFRenderLayerTree(CALayer *root, CGContextRef ctx);

// Dev test: SOFA_OFFLINE=1 makes all network requests fail (dev instances only)
BOOL SFSimulatedOffline(void);
