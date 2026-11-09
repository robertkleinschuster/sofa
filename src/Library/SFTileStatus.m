#import "SFTileStatus.h"
#import "SFDownloads.h"
#import "SFStore.h"

@implementation SFTileStatus
// Tile chips describe explicit downloads and their progress.
- (NSString *)chipTextForItem:(SFItem *)item {
    double p = 0;
    SFDownloads *dl = [SFDownloads shared];
    SFDLState s = [dl stateFor:item.identifier progress:&p];
    NSString *t = nil;
    if (s == SFDLRunning) t = [NSString stringWithFormat:@"\u2193 %d %%", (int)round(p * 100)];
    else if (s == SFDLQueued) t = @"\u2193 wartet";
    // Everywhere a downloaded video appears (channel, continue watching, history …) – just not on the
    // downloads page itself. Formerly: !localPath, but saved entries inherit the path once the video
    // played from the downloads -> the chip was missing there (WBS Legal report 2026-11-04)
    else if (s == SFDLDone && [dl isKept:item.identifier]) t = @"\u2193 Behalten";   // also on the downloads page
    else if (s == SFDLDone && [dl isPrebuffered:item.identifier]) t = nil;
    else if (s == SFDLDone && !item.inDownloadsList) t = @"\u2193 Offline";
    else if (s == SFDLRetrying) t = @"\u2193 später erneut";
    else if (s == SFDLFailed) t = @"Download fehlgeschlagen";
    return t;
}
- (double)progressForItem:(SFItem *)item { return [[SFStore shared] progressFor:item.identifier]; }
@end
