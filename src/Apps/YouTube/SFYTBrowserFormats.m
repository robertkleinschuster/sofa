#import "SFYTBrowserFormats.h"

NSDictionary *SFYTBrowserCodecs(NSArray *formats) {
    // the client's sample entry names -> the engine's codec names; what YouTube doesn't offer (hvc1) is left out
    NSDictionary *video = @{@"avc1": @"avc1", @"vp09": @"vp9", @"av01": @"av01"}, *audio = @{@"mp4a": @"mp4a", @"opus": @"opus"};
    NSMutableOrderedSet *v = [NSMutableOrderedSet new], *a = [NSMutableOrderedSet new];
    for (id f in [formats isKindOfClass:[NSArray class]] ? formats : @[]) {
        if (![f isKindOfClass:[NSString class]]) continue;
        if (video[f]) [v addObject:video[f]];
        if (audio[f]) [a addObject:audio[f]];
    }
    return @{@"vcodecs": v.count ? v.array : @[@"avc1"], @"acodecs": a.count ? a.array : @[@"mp4a"]};
}
