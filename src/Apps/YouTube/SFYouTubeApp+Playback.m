// SFApp playback and download hooks of YouTube.
//
// YouTube concept (docs/youtube.md): the sofa-yt sidecar is the one way to YouTube (playback,
// lives, downloads, preloads) - one browser identity. What it can't serve gets a clear message,
// never a second client asking for the same video (yt-dlp was that fallback until 2026-11-06:
// 1 success in 25 uses, 54 failed requests as three other clients). Every outcome is counted
// (SFCount, "yt.<what>.<outcome>").
#import "SFYouTubeApp.h"
#import "SFJSON.h"
#import "SFYTSabr.h"
#import "SFStats.h"
#import "SFDownloads.h"
#import "SFEngine.h"
#import "SFCurl.h"

static NSString *const kBotMsg = @"YouTube lässt gerade keine Wiedergabe zu – bitte in ein paar Minuten noch einmal versuchen.";

static NSString *const kNoSidecarMsg = @"Die YouTube-Wiedergabe ist in dieser Installation nicht verfügbar.";

// The sidecar's end screen elements (res/sofa-yt/lib/youtube.ts endscreenElements) as generic end
// cards (SFApp.h "endCards")
static NSArray *endCards(NSArray *elements) {
    NSMutableArray *out = [NSMutableArray new];
    for (NSDictionary *e in [elements isKindOfClass:[NSArray class]] ? elements : @[]) {
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        NSString *st = str(e[@"style"]), *vid = str(e[@"videoId"]), *pid = str(e[@"playlistId"]), *cid = str(e[@"browseId"]);
        NSMutableDictionary *c = [NSMutableDictionary new];
        if ([st isEqualToString:@"VIDEO"] && vid.length == 11) { c[@"kind"] = @"video"; c[@"ref"] = [@"yt:" stringByAppendingString:vid]; }
        else if ([st isEqualToString:@"PLAYLIST"] && pid) {
            c[@"kind"] = @"playlist"; c[@"ref"] = [@"ytplaylist:" stringByAppendingString:pid];
            if (vid.length == 11) c[@"firstRef"] = [@"yt:" stringByAppendingString:vid];
        } else if (([st isEqualToString:@"CHANNEL"] || [st isEqualToString:@"SUBSCRIBE"]) && [cid hasPrefix:@"UC"]) {
            c[@"kind"] = [st isEqualToString:@"SUBSCRIBE"] ? @"follow" : @"channel"; c[@"ref"] = [@"ytchannel:" stringByAppendingString:cid];
        } else continue;
        for (NSString *k in @[@"title", @"image", @"left", @"top", @"width", @"aspectRatio", @"startMs", @"endMs"]) if (e[k]) c[k] = e[k];
        [out addObject:c];
    }
    return out;
}

// Result of the sofa-yt sidecar -> what the player opens. VOD: the DASH pair of local tracks;
// lives and post-live DVR recordings: the sidecar's local HLS playlist (muxed, opened as is).
static void sabrPlay(NSString *vid, NSDictionary *r, SFURLDone done) {
    NSMutableDictionary *d = [r mutableCopy];
    d[@"endCards"] = endCards(r[@"endscreen"]);
    [d removeObjectForKey:@"endscreen"];
    d[@"sabr"] = @YES; d[@"vid"] = vid;
    NSURL *u;
    if ([r[@"hls"] isKindOfClass:[NSString class]]) {
        u = [NSURL URLWithString:r[@"hls"]];
        [d removeObjectsForKeys:@[@"video", @"audio", @"audios"]];   // no DASH pair: playURL opens `u` itself
        d[@"hls"] = @YES;   // flag (the URL is `u`): SFPlayerScreen asks the sidecar whether a live really ended
    } else {
        u = [NSURL URLWithString:r[@"video"]];
    }
    SFSetMPVSource(u, d);
    done(u, nil);
}

// What the viewer is told when the sidecar could not open a video.
static NSString *sabrMessage(NSError *e) {
    if ([e.userInfo[@"bot"] boolValue])   // SFYTSabr took the pause into SFYTBreaker
        return kBotMsg;
    if ([e.userInfo[@"upcoming"] boolValue]) {
        double t = [e.userInfo[@"startTime"] doubleValue];
        if (!(t > 0)) return @"Dieser Livestream hat noch nicht begonnen.";
        NSDate *at = [NSDate dateWithTimeIntervalSince1970:t];
        NSDateFormatter *f = [NSDateFormatter new];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"de_AT"];
        NSCalendar *cal = [NSCalendar currentCalendar];
        BOOL today = [cal isDateInToday:at];
        f.dateFormat = today ? @"'heute um' HH:mm 'Uhr'" : [cal isDateInTomorrow:at] ? @"'morgen um' HH:mm 'Uhr'" : @"'am' d. MMMM 'um' HH:mm 'Uhr'";
        return [NSString stringWithFormat:@"Dieser Livestream beginnt %@.", [f stringFromDate:at]];
    }
    if ([e.userInfo[@"live"] boolValue] && [e.localizedDescription isEqualToString:@"offline"])
        return @"Dieser Livestream ist gerade nicht auf Sendung.";
    if ([e.userInfo[@"unanswered"] boolValue]) return @"YouTube antwortet gerade nicht – bitte gleich noch einmal versuchen.";
    return [@"Video nicht abspielbar: " stringByAppendingString:e.localizedDescription ?: @"unbekannter Fehler"];
}

static NSString *outcome(NSError *e) {
    if ([e.userInfo[@"bot"] boolValue]) return @"bot-check";
    if ([e.userInfo[@"upcoming"] boolValue] || [e.localizedDescription isEqualToString:@"offline"]) return @"not-on-air";
    if ([e.userInfo[@"unanswered"] boolValue]) return @"unanswered";
    return @"error";
}

// SABR via the sofa-yt sidecar (looks like the web player: one request per video): local WebM/MP4
// tracks for mpv; a video that turned out to be live comes back as HLS.
static void playOnline(NSString *vid, SFURLDone done) {
    SFYTSabr *sabr = [SFYTSabr shared];
    if (!sabr.available) { SFCount(@"yt.play.no-sidecar"); done(nil, SFError(kNoSidecarMsg)); return; }
    [sabr open:vid background:NO done:^(NSDictionary *r, NSError *e) {
        if (!r) {
            SFCount([@"yt.play." stringByAppendingString:outcome(e)]);
            done(nil, SFError(sabrMessage(e))); return;
        }
        SFCount(r[@"hls"] ? @"yt.play.sabr-hls" : @"yt.play.sabr");
        sabrPlay(vid, r, done);   // a video that turned out to be live comes back as HLS
    }];
}

// Lives: the web player's HLS manifest from the sidecar's own session, as a local playlist.
static void playLive(NSString *vid, SFURLDone done) {
    SFYTSabr *sabr = [SFYTSabr shared];
    if (!sabr.available) { SFCount(@"yt.live.no-sidecar"); done(nil, SFError(kNoSidecarMsg)); return; }
    [sabr open:vid background:NO done:^(NSDictionary *r, NSError *e) {
        if (!r) {
            SFCount([@"yt.live." stringByAppendingString:outcome(e)]);
            done(nil, SFError(sabrMessage(e))); return;
        }
        SFCount(@"yt.live.sabr");   // (a former live that is a processed video by now comes back as a DASH pair: sabrPlay opens either)
        sabrPlay(vid, r, done);
    }];
}

// exact publication time from the sidecar (microformat), epoch seconds
static NSDictionary *publishedInfo(NSDictionary *r) {
    NSNumber *p = [r[@"published"] isKindOfClass:[NSNumber class]] ? r[@"published"] : nil;
    return p.doubleValue > 0 ? @{@"published": [NSDate dateWithTimeIntervalSince1970:p.doubleValue]} : nil;
}

@implementation SFYouTubeApp (Playback)

// yt:<id> plays a local download when there is one; ytlive:<id> = live/DVR via the sidecar
+ (void)resolve:(NSString *)ref done:(SFURLDone)done {
    NSString *p = SFRefPrefix(ref), *vid = SFRefID(ref);
    if ([p isEqualToString:@"ytlive"]) { playLive(vid, done); return; }
    if (![p isEqualToString:@"yt"]) { done(nil, SFError(@"Quelle nicht verfügbar")); return; }
    SFItem *local = [[SFDownloads shared] itemFor:[@"yt:" stringByAppendingString:vid]];
    if (local.localPath && [[NSFileManager defaultManager] fileExistsAtPath:local.localPath]) { done([NSURL fileURLWithPath:local.localPath], nil); return; }
    playOnline(vid, done);
}

// "Online abspielen": skip downloads
+ (void)resolveOnline:(NSString *)ref done:(SFURLDone)done {
    if ([SFRefPrefix(ref) isEqualToString:@"yt"]) playOnline(SFRefID(ref), done);
    else [self resolve:ref done:done];
}

+ (void)preloadOnFocus:(SFItem *)item {
    NSString *ref = item.resolverRef ?: item.identifier;
    if ([ref hasPrefix:@"yt:"]) [[SFYTSabr shared] preloadOnFocus:[ref substringFromIndex:3]];
}

#pragma mark Player hooks (SABR sessions of the sofa-yt sidecar)

+ (BOOL)playbackIsSession:(NSDictionary *)source { return [source[@"sabr"] boolValue]; }

// SABR (sofa-yt sidecar) failed: the player reopens via SABR (a crashed sidecar restarts and has
// the player response cached on disk - no new YouTube request) with a fresh session
+ (void)playbackSessionFailed:(NSDictionary *)source item:(SFItem *)item reason:(NSString *)why {
    SFLog(@"player: SABR stream failed (%@) -> reopening via SABR", why);
    SFCount(@"player.sabr-reopen");
    [[SFYTSabr shared] closeSession:source[@"sid"]];   // the reopen gets a fresh session, not the broken one
}

// the SABR sidecar died: its local URLs are gone - the player reopens right away instead of waiting
// for mpv's reconnects and the stall watchdog
+ (NSString *)playbackSessionLostNotification { return SFYTSabrDidExitNotification; }

// live via the sidecar: the end of the playlist is either the end of the broadcast (upstream
// EXT-X-ENDLIST, reported in the session status) or a lost playlist - only the sidecar knows
+ (BOOL)playbackLiveEnded:(NSDictionary *)source done:(void (^)(BOOL))done {
    if (!([source[@"sabr"] boolValue] && [source[@"hls"] boolValue] && [source[@"live"] boolValue])) return NO;
    [[SFYTSabr shared] sessionStatus:source[@"sid"] done:^(NSDictionary *st) { done([st[@"ended"] boolValue]); }];
    return YES;
}

#pragma mark Downloads

// still online? oEmbed answers without a player request (bot-flagged IP): 200 = public or
// unlisted -> online; 400/404 = gone (deleted, bad id). 401/403 is ambiguous (embedding off, but
// also private videos) -> unknown: never deletable in bulk, the copy may be the only one
// (review 2026-11-05). Used by "Platz schaffen" (SFDownloads+Storage.m).
+ (void)availabilityOfItem:(SFItem *)item done:(SFAvailabilityDone)done {
    NSString *vid = item.externalID ?: SFRefID(item.identifier);
    if (vid.length != 11) { done(-1); return; }
    SFBackground(^{
        NSInteger st = 0;
        NSString *u = [NSString stringWithFormat:@"https://www.youtube.com/oembed?format=json&url=https%%3A%%2F%%2Fwww.youtube.com%%2Fwatch%%3Fv%%3D%@", vid];
        SFCurlFetch(u, @"GET", nil, nil, &st, NULL);
        done(st == 200 ? 1 : (st == 400 || st == 404) ? 0 : -1);
    });
}

+ (void)downloadSourceForItem:(SFItem *)item done:(SFDownloadURLDone)done {
    NSString *vid = item.externalID ?: SFRefID(item.identifier);
    // SABR: the playback format (up to 1080p60 VP9/AV1 + Opus, original audio track) as two local
    // streams, muxed by ffmpeg into MP4 without re-encoding (ffmpeg's -readrate 3 also paces what
    // SABR pulls)
    SFYTSabr *sabr = [SFYTSabr shared];
    if (!sabr.available) { SFCount(@"yt.download.no-sidecar"); done(nil, nil, nil, SFError(kNoSidecarMsg)); return; }
    [sabr openForDownload:vid done:^(NSDictionary *r, NSError *e) {
        if (!r) {
            // a bot check defers the download without using up an attempt (backgroundPausedUntil);
            // anything else is a failed attempt, retried later
            SFCount([@"yt.download." stringByAppendingString:outcome(e)]);
            done(nil, nil, nil, e); return;
        }
        SFCount(@"yt.download.sabr");
        // the verifier needs the real length to catch a truncated file (cut-off local stream)
        if ([r[@"duration"] doubleValue] > 0) item.duration = [r[@"duration"] doubleValue];
        done([NSURL URLWithString:r[@"video"]], [NSURL URLWithString:r[@"audio"]], publishedInfo(r), nil);
    }];
}
@end
