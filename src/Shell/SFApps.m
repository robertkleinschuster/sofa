#import "SFApps.h"
#import "SFYouTubeApp.h"
#import "SFZDFApp.h"
#import "SFARDApp.h"
#import "SFORFApp.h"
#import "SFCCCApp.h"
#import "SFLibrary.h"

void SFRegisterApps(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Sofa's own look (home, settings, history, downloads)
        [SFTheme registerTheme:@"home" builder:^(SFTheme *t) {
            t.seekBarColor = [NSColor whiteColor];
            t.wordmark = @"Sofa";
            t.background = SFHex(0x0d0f14);
            t.backgroundTop = SFHex(0x232a3a);
            t.fontWordmark = @"AvenirNext-DemiBold";
            t.fontRegular = @"AvenirNext-Regular";
            t.fontMedium = @"AvenirNext-Medium";
            t.fontBold = @"AvenirNext-DemiBold";
            t.corner = 18;
        }];
        // downloads from before Sofa (Kodi era, no source tag) are YouTube videos
        [SFLibrary shared].untaggedSource = [SFYouTubeApp appIdentifier];
        // home tile order
        for (Class app in @[[SFYouTubeApp class], [SFZDFApp class], [SFARDApp class], [SFORFApp class], [SFCCCApp class]])
            [SFAppRegistry registerApp:app];
    });
}
