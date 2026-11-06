#import "SFLoungeMessages.h"
#import "SFVolume.h"

static NSString *fmtTime(double t) { return [NSString stringWithFormat:@"%.3f", (isnan(t) || t < 0) ? 0 : t]; }

@implementation SFLoungeMessages

+ (NSDictionary *)stateOf:(SFPlayerScreen *)p video:(NSString *)vid cpn:(NSString *)cpn {
    if (!p || !vid) return @{@"state": @"-1", @"currentTime": @"0", @"duration": @"0", @"loadedTime": @"0",
                             @"seekableStartTime": @"0", @"seekableEndTime": @"0", @"cpn": cpn};
    double d = [p duration];
    return @{@"state": [@(p.playbackState) stringValue], @"currentTime": fmtTime([p currentTime]), @"duration": fmtTime(d),
             @"loadedTime": fmtTime(d), @"seekableStartTime": @"0", @"seekableEndTime": fmtTime(d), @"cpn": cpn};
}

+ (NSDictionary *)nowPlayingOf:(SFPlayerScreen *)p video:(NSString *)vid cpn:(NSString *)cpn {
    if (!vid) return @{};
    NSMutableDictionary *a = [[self stateOf:p video:vid cpn:cpn] mutableCopy];
    a[@"videoId"] = vid;
    a[@"currentIndex"] = [@(p.remoteListID ? p.queueIndex : 0) stringValue];
    if (p.remoteListID) a[@"listId"] = p.remoteListID;
    return a;
}

// like gotubecast: languageCode "" = off; vss_id ".de" = real, "a.de" = automatic subtitles
// (YouTube's track ID, the phone marks its list by it)
+ (NSArray *)subtitles:(NSDictionary *)st video:(NSString *)vid {
    NSString *lang = vid ? st[@"lang"] : nil;
    if (!lang.length) return @[@"onSubtitlesTrackChanged", @{@"videoId": vid ?: @""}];
    return @[@"onSubtitlesTrackChanged", @{@"videoId": vid, @"languageCode": lang,
                                           @"vss_id": [([st[@"kind"] isEqual:@"auto"] ? @"a." : @".") stringByAppendingString:lang]}];
}

+ (NSArray *)volume {
    int vol = (int)lroundf(MAX(0, [SFVolume volume]) * 100);
    return @[@"onVolumeChanged", @{@"volume": [@(vol) stringValue], @"muted": [SFVolume muted] ? @"true" : @"false"}];
}

+ (NSArray *)fullStateOf:(SFPlayerScreen *)p video:(NSString *)vid cpn:(NSString *)cpn {
    return @[@[@"onHasPreviousNextChanged", @{@"hasPrevious": p.hasPrevious ? @"true" : @"false", @"hasNext": p.hasNext ? @"true" : @"false"}],
             @[@"nowPlaying", [self nowPlayingOf:p video:vid cpn:cpn]],
             @[@"onStateChange", [self stateOf:p video:vid cpn:cpn]],
             [self volume],
             @[@"onAutoplayModeChanged", @{@"autoplayMode": @"UNSUPPORTED"}]];
}
@end
