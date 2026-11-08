#import "SFPlayerBar.h"
#import "SFCore.h"

SFBarMode SFBarModeFor(SFItemKind kind, NSTimeInterval duration) {
    if (kind == SFItemLive) return SFBarLive;
    return duration > 0 ? SFBarVideo : SFBarLoading;
}

NSString *SFBarElapsedText(SFBarMode mode, NSTimeInterval shown) {
    switch (mode) {
        case SFBarLive: return @"LIVE";
        case SFBarLoading: return shown >= 1 ? SFFormatDuration(shown) : @"";
        case SFBarVideo: return shown >= 1 ? (SFFormatDuration(shown) ?: @"0:00") : @"0:00";
    }
    return @"";
}
