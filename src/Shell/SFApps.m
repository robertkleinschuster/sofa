#import "SFApps.h"
#import "SFYouTubeApp.h"
#import "SFZDFApp.h"
#import "SFARDApp.h"
#import "SFORFApp.h"
#import "SFCCCApp.h"
#import "SFExampleApp.h"
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
        NSArray *apps = @[[SFYouTubeApp class], [SFZDFApp class], [SFARDApp class], [SFORFApp class], [SFCCCApp class]];
        if (SFDevMode && (getenv("SOFA_EXAMPLE_APP") || getenv("SOFA_ONLY_APPS"))) apps = [apps arrayByAddingObject:[SFExampleApp class]];   // template app (docs/new-app.md)
        // dev: SOFA_ONLY_APPS=example,zdf registers only those (tests without any network request)
        NSString *only = SFDevMode && getenv("SOFA_ONLY_APPS") ? @(getenv("SOFA_ONLY_APPS")) : nil;
        for (Class<SFApp> app in apps)
            if (!only || [[only componentsSeparatedByString:@","] containsObject:[app appIdentifier]]) [SFAppRegistry registerApp:app];
    });
}
