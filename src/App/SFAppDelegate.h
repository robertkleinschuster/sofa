// SFAppDelegate – private header for main.m and its categories
// (SFAppDelegate+Lounge.m: phone commands, +Update.m: state across app updates, +Dev.m: dev FIFO).
#import "SFCore.h"
#import "SFScreen.h"
@class SFPlayerScreen, SFRemote, SFDevServer;

extern NSString *gInstance;   // dev instance name (--instance)
void SFClearRunningMarker(void);   // autostart crash detection, see main()

@interface SFWindow : NSWindow @end

@interface SFAppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) SFWindow *window;
@property (nonatomic, strong) SFNavigator *nav;
@property (nonatomic) NSSize devSize;
// internal (used by the categories)
@property (nonatomic, strong) dispatch_source_t fifoSrc;
@property (nonatomic, strong) NSMutableString *fifoBuf;
@property (nonatomic) NSUInteger loungeGen;
- (void)hideCursor:(BOOL)hide;
- (void)welcomeIfFirstRun;
@end

@interface SFAppDelegate (Lounge)
- (SFPlayerScreen *)topPlayer;
- (void)presentPlayer:(SFPlayerScreen *)ps;   // replaces the visible player (and overlays above it) or pushes
- (void)wakeAndFront;
- (void)loungeCommand:(NSString *)cmd args:(NSDictionary *)args;
@end

@interface SFAppDelegate (Update)
- (NSString *)resumePath;
- (void)prepareForUpdate;
- (void)restoreAfterUpdate;
@end

@interface SFAppDelegate (Dev)
- (void)startFifo;
- (void)devCommand:(NSString *)line;
- (void)screenshot:(NSString *)path;
@end
