// Sofa — 10-foot media center for macOS 10.9 (Apple Remote, AVFoundation).
// Gemeinsame Grundlagen: Eingabe-Tasten, Layout-Skalierung, Logging, Helfer.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

typedef NS_ENUM(NSInteger, SFKey) {
    SFKeyUp, SFKeyDown, SFKeyLeft, SFKeyRight,
    SFKeySelect, SFKeyMenu, SFKeyPlayPause,
    SFKeySelectHold, SFKeyMenuHold,
    SFKeyNext, SFKeyPrev,      // Spulen (Remote-Hold links/rechts, Tastatur ,/.)
    SFKeyUpHold, SFKeyDownHold,
};

// Alle Layout-Masse sind in "Design-Einheiten" einer 1920x1080-Fläche angegeben
// und werden mit SFScale auf die echte Bildschirmhöhe skaliert.
extern CGFloat SFScale;
static inline CGFloat U(CGFloat v) { return round(v * SFScale); }

void SFLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
extern NSString *SFLogFileName;   // "Sofa.log"; Dev-Instanzen: "Sofa-dev-<instanz>.log"

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

// Animations-Helfer: alle Änderungen im Block mit einheitlicher Kurve animieren.
void SFAnimate(CFTimeInterval dur, dispatch_block_t changes);
void SFNoAnimate(dispatch_block_t changes);

extern BOOL SFDevMode;   // unsichtbarer Entwicklungsmodus (main.m)

// Dev: Ebenenbaum in Kontext rendern (Modell-Ebenen, AVPlayerLayer ausgespart —
// presentationLayer-Kopien der AVPlayerLayer crashen bei Freigabe auf 10.9).
void SFRenderLayerTree(CALayer *root, CGContextRef ctx);

// Dev-Test: SOFA_OFFLINE=1 lässt alle Netzanfragen scheitern (nur Dev-Instanzen)
BOOL SFSimulatedOffline(void);
