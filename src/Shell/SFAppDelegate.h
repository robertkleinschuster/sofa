// SFAppDelegate – private header for main.m and its categories
// (SFAppDelegate+Player.m: player host for phone remotes/dev commands, +Update.m: state across app updates, +Dev.m: dev FIFO).
#import "SFCore.h"
#import "SFScreen.h"
#import "SFPlayerHost.h"
@class SFPlayerScreen, SFRemote;

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
@property (nonatomic) BOOL fifoStopped;   // quit began: a pipe set up after this is not listened to
- (void)hideCursor:(BOOL)hide;
- (void)welcomeIfFirstRun;
@end

@interface SFAppDelegate (Player) <SFPlayerHost>
- (SFPlayerScreen *)topPlayer;
- (void)presentPlayer:(SFPlayerScreen *)ps;   // replaces the visible player (and overlays above it) or pushes
- (void)wakeAndFront;
@end

@interface SFAppDelegate (Update)
- (NSString *)resumePath;
- (void)prepareForUpdate;
- (void)restoreAfterUpdate;
@end

@interface SFAppDelegate (Dev)
- (void)startFifo;
- (void)stopFifo;
- (void)devCommand:(NSString *)line;
- (void)screenshot:(NSString *)path;
@end
