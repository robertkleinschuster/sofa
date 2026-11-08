// SFApp playback and download hooks of YouTube.
//
// YouTube concept (docs/youtube.md): the YouTube engine (SFYTEngine: a real Firefox) is the one way to YouTube (playback,
// lives, downloads, preloads) - one browser identity. What it can't serve gets a clear message,
// never a second client asking for the same video (yt-dlp was that fallback until 2026-11-06:
// 1 success in 25 uses, 54 failed requests as three other clients). Every outcome is counted
// (SFCount, "yt.<what>.<outcome>").
#import "SFYouTubeApp.h"
#import "SFJSON.h"
#import "SFYTEngine.h"
#import "SFStats.h"
#import "SFDownloads.h"
#import "SFEngine.h"
#import "SFYTWatch.h"

static NSString *const kBotMsg = @"YouTube lässt gerade keine Wiedergabe zu – bitte in ein paar Minuten noch einmal versuchen.";

static NSString *const kNoEngineMsg = @"Die YouTube-Wiedergabe ist in dieser Installation nicht verfügbar.";

// The engine's end screen elements (res/sofa-yt/lib/youtube.ts endscreenElements) as generic end
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

// Result of the engine -> what the player opens. VOD: the DASH pair of local tracks;
// lives and post-live DVR recordings: the engine's local HLS playlist (muxed, opened as is).
static void sabrPlay(NSString *vid, NSDictionary *r, SFURLDone done) {
    NSMutableDictionary *d = [r mutableCopy];
    d[@"endCards"] = endCards(r[@"endscreen"]);
    [d removeObjectForKey:@"endscreen"];
    d[@"sabr"] = @YES; d[@"vid"] = vid;
    NSURL *u;
    if ([r[@"hls"] isKindOfClass:[NSString class]]) {
        u = [NSURL URLWithString:r[@"hls"]];
        [d removeObjectsForKeys:@[@"video", @"audio", @"audios"]];   // no DASH pair: playURL opens `u` itself
        d[@"hls"] = @YES;   // flag (the URL is `u`): SFPlayerScreen asks the engine whether a live really ended
    } else {
        u = [NSURL URLWithString:r[@"video"]];
    }
    SFSetMPVSource(u, d);
    done(u, nil);
}

// What the viewer is told when the engine could not open a video.
static NSString *sabrMessage(NSError *e) {
    if ([e.userInfo[@"bot"] boolValue])   // SFYTEngine took the pause into SFYTBreaker
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

// The watch page (/next) a few seconds into a playback, as youtube.com's watch navigation asks for it
// (captured 2026-11-07: /next ~4.7 s after the navigation) - instead of at half time (autoplay) or
// when the info panel opens. Cached (SFYTWatch, 30 min): autoplay and the info panel use the same
// answer, so it adds no request, it only comes when a browser's would.
static void watchPageSoon(NSString *vid) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [SFYTWatch watchPageFor:vid done:^(NSArray *related, NSDictionary *details) {}];
    });
}

// SABR via the engine (like the web player: one request per video): local WebM/MP4
// tracks for mpv; a video that turned out to be live comes back as HLS.
// fromStore: a video complete in the media store plays from there (no engine, offline too); NO =
// "Online abspielen" (every audio and subtitle track - what is on disk is still read from there)
static void playOnline(NSString *vid, BOOL fromStore, SFURLDone done) {
    SFYTEngine *engine = [SFYTEngine shared];
    if (![engine canOpen:vid]) { SFCount(@"yt.play.no-engine"); done(nil, SFError(kNoEngineMsg)); return; }
    [engine open:vid background:NO stored:fromStore done:^(NSDictionary *r, NSError *e) {
        if (!r) {
            SFCount([@"yt.play." stringByAppendingString:outcome(e)]);
            done(nil, SFError(sabrMessage(e))); return;
        }
        SFCount(r[@"stored"] ? @"yt.play.stored" : r[@"hls"] ? @"yt.play.sabr-hls" : @"yt.play.sabr");
        sabrPlay(vid, r, done);   // a video that turned out to be live comes back as HLS
        if (!r[@"stored"]) watchPageSoon(vid);   // (from the store: no YouTube page view behind it)
    }];
}

// Lives: the web player's HLS manifest from the engine's own session, as a local playlist.
static void playLive(NSString *vid, SFURLDone done) {
    SFYTEngine *engine = [SFYTEngine shared];
    if (!engine.available) { SFCount(@"yt.live.no-engine"); done(nil, SFError(kNoEngineMsg)); return; }
    [engine open:vid background:NO stored:NO done:^(NSDictionary *r, NSError *e) {
        if (!r) {
            SFCount([@"yt.live." stringByAppendingString:outcome(e)]);
            done(nil, SFError(sabrMessage(e))); return;
        }
        SFCount(@"yt.live.sabr");   // (a former live that is a processed video by now comes back as a DASH pair: sabrPlay opens either)
        sabrPlay(vid, r, done);
    }];
}

// exact publication time from the engine (microformat), epoch seconds
static NSDictionary *publishedInfo(NSDictionary *r) {
    NSNumber *p = [r[@"published"] isKindOfClass:[NSNumber class]] ? r[@"published"] : nil;
    return p.doubleValue > 0 ? @{@"published": [NSDate dateWithTimeIntervalSince1970:p.doubleValue]} : nil;
}

@implementation SFYouTubeApp (Playback)

// yt:<id> plays from the media store when it is complete there; ytlive:<id> = live/DVR via the engine
+ (void)resolve:(NSString *)ref done:(SFURLDone)done {
    NSString *p = SFRefPrefix(ref), *vid = SFRefID(ref);
    if ([p isEqualToString:@"ytlive"]) { playLive(vid, done); return; }
    if (![p isEqualToString:@"yt"]) { done(nil, SFError(@"Quelle nicht verfügbar")); return; }
    playOnline(vid, YES, done);
}

// "Online abspielen": not the store's session
+ (void)resolveOnline:(NSString *)ref done:(SFURLDone)done {
    if ([SFRefPrefix(ref) isEqualToString:@"yt"]) playOnline(SFRefID(ref), NO, done);
    else [self resolve:ref done:done];
}

+ (void)preloadOnFocus:(SFItem *)item {
    NSString *ref = item.resolverRef ?: item.identifier;
    if ([ref hasPrefix:@"yt:"]) [[SFYTEngine shared] preloadOnFocus:[ref substringFromIndex:3]];
}

#pragma mark Player hooks (SABR sessions of the engine)

+ (BOOL)playbackIsSession:(NSDictionary *)source { return [source[@"sabr"] boolValue]; }

// The session's media from the start point on, before mpv asks: the resume position's first bytes
// were mpv's to request after probing and seeking - 5-6 s of a 12-s start (2026-11-07).
+ (void)playback:(NSDictionary *)source startsAt:(NSTimeInterval)seconds {
    NSString *sid = [source[@"sid"] isKindOfClass:[NSString class]] ? source[@"sid"] : nil;
    if ([source[@"sabr"] boolValue] && ![source[@"hls"] boolValue] && sid) [[SFYTEngine shared] session:sid startsAt:seconds];
}

// a SABR session failed: the player reopens it via the engine (its player response is cached
// there - no new YouTube request) as a fresh session
+ (void)playbackSessionFailed:(NSDictionary *)source item:(SFItem *)item reason:(NSString *)why {
    SFLog(@"player: SABR stream failed (%@) -> reopening via SABR", why);
    SFCount(@"player.sabr-reopen");
    [[SFYTEngine shared] closeSession:source[@"sid"]];   // the reopen gets a fresh session, not the broken one
}

// the engine's page went away: its local URLs are gone - the player reopens right away instead of waiting
// for mpv's reconnects and the stall watchdog
+ (NSString *)playbackSessionLostNotification { return SFYTEngineSessionsLostNotification; }

// live via the engine: the end of the playlist is either the end of the broadcast (upstream
// EXT-X-ENDLIST, reported in the session status) or a lost playlist - only the engine knows
+ (BOOL)playbackLiveEnded:(NSDictionary *)source done:(void (^)(BOOL))done {
    if (!([source[@"sabr"] boolValue] && [source[@"hls"] boolValue] && [source[@"live"] boolValue])) return NO;
    [[SFYTEngine shared] sessionStatus:source[@"sid"] done:^(NSDictionary *st) { done([st[@"ended"] boolValue]); }];
    return YES;
}

#pragma mark Downloads

// still online? oEmbed answers without a player request (bot-flagged IP), asked by the engine's
// page like everything else of YouTube: 200 = public or unlisted -> online; 400/404 = gone (deleted,
// bad id). 401/403 is ambiguous (embedding off, but also private videos) -> unknown: never deletable
// in bulk, the copy may be the only one (review 2026-11-05). Used by "Platz schaffen"
// (SFDownloads+Storage.m).
+ (void)availabilityOfItem:(SFItem *)item done:(SFAvailabilityDone)done {
    NSString *vid = item.externalID ?: SFRefID(item.identifier);
    if (vid.length != 11) { done(-1); return; }
    SFMain(^{ [[SFYTEngine shared] availability:vid done:done]; });
}

// A download is the media store filled with the playback format (up to 1080p60 VP9/AV1 + Opus,
// original audio track) and its subtitles - played back as a stored session (SFYTEngine+Store.m).
+ (dispatch_block_t)fillItem:(SFItem *)item progress:(void (^)(double))progress done:(void (^)(NSDictionary *, NSError *))done {
    NSString *vid = item.externalID ?: SFRefID(item.identifier);
    SFYTEngine *engine = [SFYTEngine shared];
    if (![engine canOpen:vid]) { SFCount(@"yt.download.no-engine"); done(nil, SFError(kNoEngineMsg)); return ^{}; }
    return [engine fill:vid progress:progress done:^(NSDictionary *r, NSError *e) {
        // a bot check defers the download without using up an attempt (backgroundPausedUntil);
        // anything else is a failed attempt, retried later
        SFCount(r ? @"yt.download.filled" : [@"yt.download." stringByAppendingString:outcome(e)]);
        done(r ? (publishedInfo(r) ?: @{}) : nil, e);
    }];
}
@end
