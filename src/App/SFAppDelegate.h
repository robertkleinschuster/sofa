// SFAppDelegate – privater Header für main.m und seine Kategorien
// (SFAppDelegate+Lounge.m: Handy-Befehle, +Update.m: Zustand über App-Updates, +Dev.m: Dev-FIFO).
#import "SFCore.h"
#import "SFScreen.h"
@class SFPlayerScreen, SFRemote, SFDevServer;

extern NSString *gInstance;   // Dev-Instanzname (--instance)
void SFClearRunningMarker(void);   // Autostart-Absturzerkennung, siehe main()

@interface SFWindow : NSWindow @end

@interface SFAppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) SFWindow *window;
@property (nonatomic, strong) SFNavigator *nav;
@property (nonatomic) NSSize devSize;
// intern (von den Kategorien genutzt)
@property (nonatomic, strong) dispatch_source_t fifoSrc;
@property (nonatomic, strong) NSMutableString *fifoBuf;
@property (nonatomic) NSUInteger loungeGen;
- (void)hideCursor:(BOOL)hide;
- (void)welcomeIfFirstRun;
@end

@interface SFAppDelegate (Lounge)
- (SFPlayerScreen *)topPlayer;
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
