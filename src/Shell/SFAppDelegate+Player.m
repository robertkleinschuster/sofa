#import "SFCore.h"
#import "SFScreen.h"
#import "SFHome.h"
#import "SFMenuScreen.h"
#import "SFRemote.h"
#import "SFStore.h"
#import "SFDevServer.h"
#import "SFMPVEngine.h"
#import "SFNet.h"
#import "SFPower.h"
#import "SFDownloads.h"
#import "SFPlayerScreen.h"
#import <IOKit/pwr_mgt/IOPMLib.h>
#import "SFPlayerScreen.h"
#import "SFLayers.h"
#import "SFRuntime.h"
#import "SFSettings.h"
#import "SFUpdater.h"
#import <ImageIO/ImageIO.h>
#include <sys/stat.h>
#import "SFAppDelegate.h"

@implementation SFAppDelegate (Player)

#pragma mark Player host (SFPlayerHost): phone remote, dev commands

// The visible player: the top screen, or the one right below overlays (menu, info panel) - the
// video keeps playing under them and stays controllable from the phone
- (SFPlayerScreen *)topPlayer {
    for (SFScreen *s in [self.nav.stack reverseObjectEnumerator]) {
        if ([s isKindOfClass:[SFPlayerScreen class]]) return (SFPlayerScreen *)s;
        if (s.isOpaque) return nil;
    }
    return nil;
}

// Show a new player in place of the visible one (overlays above it go away) or on top
- (void)presentPlayer:(SFPlayerScreen *)ps {
    SFPlayerScreen *cur = [self topPlayer];
    if (cur) { [self.nav popAbove:cur]; [self.nav replaceTop:ps]; }
    else [self.nav push:ps];
}

- (void)wakeAndFront {
    if (SFDevMode) return;
    IOPMAssertionID a = 0;
    IOPMAssertionDeclareUserActivity(CFSTR("Sofa: Handy"), kIOPMUserActiveLocal, &a);   // wakes the display
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
}

@end
