#import "SFWebTV.h"
#import "SFPlayerScreen.h"
#import "SFWebItems.h"
#import "SFWebStreams.h"
#import "SFWebErrors.h"

static const NSTimeInterval kSameSpot = 3;   // a handed-over position this close to the TV's is where it is

static NSString *StateName(SFPlayerScreen *p) {
    switch (p.playbackState) {
        case SFPlaybackPlaying: return @"playing";
        case SFPlaybackPaused: return @"paused";
        case SFPlaybackBuffering: return @"buffering";
        case SFPlaybackEnded: return @"ended";
        default: return @"failed";   // idle with a player on screen: its start or stream failed (its message is shown)
    }
}

// a player someone may be watching: replacing it asks first
static BOOL Busy(SFPlayerScreen *p) {
    SFPlaybackState st = p.playbackState;
    return p && (st == SFPlaybackPlaying || st == SFPlaybackPaused || st == SFPlaybackBuffering);
}

@implementation SFWebTV

+ (instancetype)shared {
    static SFWebTV *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SFWebTV new]; });
    return s;
}

- (void)play:(SFItem *)item fromStart:(BOOL)fromStart at:(NSTimeInterval)at replace:(BOOL)replace device:(NSString *)device
        done:(void (^)(NSInteger, NSDictionary *))done {
    id<SFPlayerHost> host = self.host;
    if (!host) { done(503, SFWebError(SFWebErrNotReady, @"Der Fernseher ist gerade nicht bereit.")); return; }
    if (item.drm) { done(403, SFWebError(SFWebErrDRM, SFDRMNotice)); return; }
    if (item.kind != SFItemVideo && item.kind != SFItemLive) { done(400, SFWebError(SFWebErrNotVideo, @"Das ist kein Video.")); return; }
    BOOL live = item.kind == SFItemLive;
    SFPlayerScreen *cur = [host topPlayer];
    if (Busy(cur) && [cur.item.identifier isEqualToString:item.identifier]) {
        // already on the TV: it plays on (never reopened), at the handed-over spot if there is one
        [[SFWebStreams shared] endItem:item.identifier device:device why:@"sent to the TV"];
        if (!live && at > 0 && fabs([cur currentTime] - at) > kSameSpot) [cur remoteSeekTo:at];
        else if (!live && fromStart) [cur remoteSeekTo:0];
        [host wakeAndFront];
        [cur remotePlay];
        SFLog(@"web: %@ is on the TV already - plays on (device %@)", item.identifier, device);
        done(200, @{@"tv": [self state] ?: [NSNull null], @"already": @YES});
        return;
    }
    if (Busy(cur) && !replace) {
        NSString *title = cur.item.title ?: @"ein Video";
        SFLog(@"web: %@ not sent to the TV - %@ plays there (device %@ asked first)", item.identifier, cur.item.identifier, device);
        NSMutableDictionary *busy = [SFWebError(SFWebErrTVBusy, [NSString stringWithFormat:@"Am Fernseher läuft gerade „%@“.", title]) mutableCopy];
        busy[@"busy"] = @{@"title": title};
        done(409, busy);
        return;
    }
    [[SFWebStreams shared] endItem:item.identifier device:device why:@"sent to the TV"];
    SFPlayerScreen *ps = [[SFPlayerScreen alloc] initWithItem:item queue:nil index:0];
    if (!live && at > 0) ps.startPosition = at;
    else if (!live && fromStart) ps.startFromBeginning = YES;
    [host wakeAndFront];
    [host presentPlayer:ps];
    SFLog(@"web: %@ sent to the TV (device %@%@)", item.identifier, device, cur ? @", replaced the player" : @"");
    done(200, @{@"tv": [self state] ?: [NSNull null]});
}

- (NSDictionary *)state {
    SFPlayerScreen *p = [self.host topPlayer];
    NSDictionary *item = p.item ? [SFWebItems item:p.item] : nil;
    if (!item) return nil;
    BOOL live = p.item.kind == SFItemLive;
    NSTimeInterval d = [p duration];
    return @{@"item": item, @"state": StateName(p), @"position": @(live ? 0 : MAX(0, [p currentTime])),
             @"duration": @(!live && d > 0 && isfinite(d) ? d : 0), @"live": @(live)};
}

- (NSInteger)control:(NSString *)action {
    SFPlayerScreen *p = [self.host topPlayer];
    if (!p) return 404;
    if ([action isEqualToString:@"pause"]) [p remotePause];
    else if ([action isEqualToString:@"play"]) { [self.host wakeAndFront]; [p remotePlay]; }
    else if ([action isEqualToString:@"stop"]) [p close];
    else return 400;
    SFLog(@"web: TV %@", action);
    return 200;
}
@end
