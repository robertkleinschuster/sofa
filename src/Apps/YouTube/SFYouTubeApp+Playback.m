// SFApp playback and download hooks of YouTube.
//
// YouTube concept (docs/youtube.md): the sofa-yt sidecar is the one way to YouTube (playback,
// lives, downloads, preloads, PO tokens); yt-dlp (SFYTResolver) is the fallback when the sidecar
// could not serve a video - never after a bot check (SFYTBreaker). Every decision is counted
// (SFCount, "yt.<what>.<path>[.<reason>]") so unused fallbacks can be retired on data.
//
// While the bot-check breaker is open, no path falls back to yt-dlp - not only when the sidecar's
// own answer was the bot check, but also when the sidecar is restarting, timed out or skipped
// (review 2026-11-05): a fallback player request from the flagged IP only prolongs the flag.
#import "SFYouTubeApp.h"
#import "SFJSON.h"
#import "SFYTResolver.h"
#import "SFYTSabr.h"
#import "SFYTBreaker.h"
#import "SFStats.h"
#import "SFDownloads.h"
#import "SFEngine.h"
#import "SFSettings.h"
#import "SFCurl.h"

static NSString *const kBotMsg = @"YouTube lässt gerade keine Wiedergabe zu – bitte in ein paar Minuten noch einmal versuchen.";

static BOOL botPaused(SFURLDone done) {
    if (![SFYTBreaker shared].blockedUntil) return NO;
    SFLog(@"yt: bot-check pause - no yt-dlp fallback");
    SFCount(@"yt.ytdlp.skipped-bot-pause");
    done(nil, SFError(kBotMsg));
    return YES;
}

// yt-dlp: HLS (+ DASH for mpv) via the resolver process
static void ytdlp(NSString *vid, SFURLDone done) {
    if (botPaused(done)) return;
    [[SFYTResolver shared] resolve:vid live:NO done:^(NSDictionary *r, NSError *e) {
        NSURL *u = r ? [NSURL URLWithString:r[@"url"]] : nil;
        if (u) SFSetAlternateURLs(u, r[@"alt"]);
        if (u) {   // VP9/AV1 (DASH) for the mpv engine, plus audio/subtitle tracks
            NSMutableDictionary *d = [r[@"dash"] isKindOfClass:[NSDictionary class]] ? [r[@"dash"] mutableCopy] : [NSMutableDictionary new];
            if (r[@"height"]) d[@"hlsHeight"] = r[@"height"];
            if (r[@"fps"]) d[@"hlsFps"] = r[@"fps"];
            if ([r[@"subs"] isKindOfClass:[NSArray class]]) d[@"subs"] = r[@"subs"];
            SFSetMPVSource(u, d);
        }
        done(u, e);
    }];
}

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

// A sidecar error that needs no fallback request: bot check (yt-dlp from the same IP would only
// prolong the flag, review 2026-11-05) and streams that are not on air (yt-dlp can't play them
// either). Returns the message for the user, nil = fall back to yt-dlp.
static NSString *sabrFinal(NSError *e) {
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
    return nil;
}

// First choice: SABR via the sofa-yt sidecar (looks like the web player: one request per video,
// passes where yt-dlp gets bot checks). Needs mpv (local WebM/MP4 tracks). yt-dlp only where the
// sidecar can't play the video - never as a second asker when YouTube did not answer (`unanswered`)
// or refused (bot check): that would be another identity requesting the same video.
static void playOnline(NSString *vid, SFURLDone done) {
    SFYTSabr *sabr = [SFYTSabr shared];
    if (![sabr usableFor:vid]) {
        SFCount(!sabr.available ? @"yt.play.ytdlp.no-sidecar" : [sabr failedFor:vid] ? @"yt.play.ytdlp.marked-failed" : @"yt.play.ytdlp.no-mpv");
        ytdlp(vid, done); return;
    }
    [sabr open:vid background:NO done:^(NSDictionary *r, NSError *e) {
        if (!r) {
            NSString *msg = sabrFinal(e);
            if (msg) { SFCount([e.userInfo[@"bot"] boolValue] ? @"yt.play.bot-check" : @"yt.play.not-on-air"); done(nil, SFError(msg)); return; }
            if ([e.userInfo[@"unanswered"] boolValue]) { SFCount(@"yt.play.unanswered"); done(nil, SFError(@"YouTube antwortet gerade nicht.")); return; }
            if ([e.userInfo[@"live"] boolValue]) [sabr markFailed:vid];   // live the sidecar can't play: yt-dlp directly next time
            SFLog(@"yt: SABR unavailable for %@ (%@) -> yt-dlp", vid, e.localizedDescription);
            SFCount(@"yt.play.ytdlp.sidecar-error");
            ytdlp(vid, done); return;
        }
        SFCount(r[@"hls"] ? @"yt.play.sabr-hls" : @"yt.play.sabr");
        sabrPlay(vid, r, done);   // a video that turned out to be live comes back as HLS
    }];
}

// Lives: the sidecar first (the web player's HLS manifest from its own session - yt-dlp's live
// requests got the bot check on this IP), yt-dlp as fallback. The local playlist is plain HLS:
// mpv and AVFoundation both play it, so no mpv requirement here.
static void ytdlpLive(NSString *vid, SFURLDone done) {
    if (botPaused(done)) return;
    [[SFYTResolver shared] resolve:vid live:YES done:^(NSDictionary *r, NSError *e) {
        done(r ? [NSURL URLWithString:r[@"url"]] : nil, e);
    }];
}

static void playLive(NSString *vid, SFURLDone done) {
    SFYTSabr *sabr = [SFYTSabr shared];
    if (!sabr.available || [sabr failedFor:vid]) {
        SFCount(!sabr.available ? @"yt.live.ytdlp.no-sidecar" : @"yt.live.ytdlp.marked-failed");
        ytdlpLive(vid, done); return;
    }
    [sabr open:vid background:NO done:^(NSDictionary *r, NSError *e) {
        if (!r) {
            NSString *msg = sabrFinal(e);
            if (msg) { SFCount([e.userInfo[@"bot"] boolValue] ? @"yt.live.bot-check" : @"yt.live.not-on-air"); done(nil, SFError(msg)); return; }
            if ([e.userInfo[@"unanswered"] boolValue]) { SFCount(@"yt.live.unanswered"); done(nil, SFError(@"YouTube antwortet gerade nicht.")); return; }
            SFLog(@"yt: SABR live unavailable for %@ (%@) -> yt-dlp", vid, e.localizedDescription);
            SFCount(@"yt.live.ytdlp.sidecar-error");
            ytdlpLive(vid, done); return;
        }
        // a former live that is a processed video by now comes back as a DASH pair: needs mpv
        if (!r[@"hls"] && (!SFMPVAvailable() || SFPreferAVFoundation())) { SFCount(@"yt.live.ytdlp.no-mpv"); ytdlpLive(vid, done); return; }
        SFCount(@"yt.live.sabr");
        sabrPlay(vid, r, done);
    }];
}

// exact publication time from the sidecar (microformat) or yt-dlp (timestamp), epoch seconds
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

+ (void)prepareForRelaunch { [[SFYTResolver shared] saveCache]; }

#pragma mark Player hooks (SABR sessions of the sofa-yt sidecar)

+ (BOOL)playbackIsSession:(NSDictionary *)source { return [source[@"sabr"] boolValue]; }

// SABR (sofa-yt sidecar) failed: first reopen via SABR (a crashed sidecar restarts and has the
// player response cached on disk - no new YouTube request), then yt-dlp takes over (the
// resolver skips SABR for this video from now on)
+ (void)playbackSessionFailed:(NSDictionary *)source item:(SFItem *)item retried:(BOOL)retried reason:(NSString *)why {
    SFLog(@"player: SABR stream failed (%@) -> %@", why, retried ? @"yt-dlp" : @"reopening via SABR");
    SFCount(retried ? @"player.sabr-to-ytdlp" : @"player.sabr-reopen");
    if (retried) [[SFYTSabr shared] markFailed:source[@"vid"]];
    else [[SFYTSabr shared] closeSession:source[@"sid"]];   // the retry gets a fresh session, not the broken one
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

// YouTube URLs are sporadically rejected entirely (403/-1102): resolve afresh once
+ (BOOL)playbackPrepareReResolve:(SFItem *)item {
    NSString *ref = item.resolverRef ?: item.identifier;
    if (![SFRefPrefix(ref) isEqualToString:@"yt"]) return NO;
    [[SFYTResolver shared] forget:SFRefID(ref)];
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

// YouTube downloads wait during a bot-check pause (no request, no attempt used up)
+ (NSTimeInterval)downloadsPausedUntil { return [SFYTBreaker shared].blockedUntil; }

+ (void)downloadSourceForItem:(SFItem *)item done:(SFDownloadURLDone)done {
    NSString *vid = item.externalID ?: SFRefID(item.identifier);
    void (^viaYTDLP)(void) = ^{
        [[SFYTResolver shared] prefetch:vid done:^(NSDictionary *r, NSError *e) {
            // the playback format, as with SABR: DASH video + the original audio track (mweb, the
            // first client, has no HLS any more); otherwise the muxed/HLS stream as before
            NSDictionary *d = [r[@"dash"] isKindOfClass:[NSDictionary class]] ? r[@"dash"] : nil;
            if ([d[@"video"] isKindOfClass:[NSString class]] && [d[@"audio"] isKindOfClass:[NSString class]]) {
                done([NSURL URLWithString:d[@"video"]], [NSURL URLWithString:d[@"audio"]], publishedInfo(r), nil); return;
            }
            NSString *u = r[@"url"];
            for (NSString *a in r[@"alt"]) if ([a rangeOfString:@"/itag/95/"].location != NSNotFound) { u = a; break; }
            // several audio tracks: original audio separately (the muxed stream has YouTube's default track)
            NSString *au = r[@"dlaudio"];
            done(u ? [NSURL URLWithString:u] : nil, au ? [NSURL URLWithString:au] : nil, publishedInfo(r), e);
        }];
    };
    // first choice SABR: the playback format (up to 1080p60 VP9/AV1 + Opus, original audio track)
    // as two local streams, muxed by ffmpeg into MP4 without re-encoding (ffmpeg's -readrate 3
    // also paces what SABR pulls). yt-dlp stays the fallback (2026-11-05: yt-dlp's stream address
    // of _4O-me6dWfc answered 404 for hours; the SABR repair worked at once).
    SFYTSabr *sabr = [SFYTSabr shared];
    if (!sabr.available) { SFCount(@"yt.download.ytdlp.no-sidecar"); viaYTDLP(); return; }
    [sabr openForDownload:vid done:^(NSDictionary *r, NSError *e) {
        if (!r) {
            // a bot check pauses both paths alike (SFYTSabr noted it in SFYTBreaker): no yt-dlp
            // request; the download is deferred without using up an attempt
            if ([e.userInfo[@"bot"] boolValue]) { SFCount(@"yt.download.bot-check"); done(nil, nil, nil, e); return; }
            // YouTube did not answer: a normal failed attempt (retried later), not yt-dlp asking instead
            if ([e.userInfo[@"unanswered"] boolValue]) { SFCount(@"yt.download.unanswered"); done(nil, nil, nil, e); return; }
            SFLog(@"yt: SABR download of %@ unavailable (%@) -> yt-dlp", vid, e.localizedDescription);
            SFCount(@"yt.download.ytdlp.sidecar-error");
            viaYTDLP(); return;
        }
        SFCount(@"yt.download.sabr");
        // the verifier needs the real length to catch a truncated file (cut-off local stream)
        if ([r[@"duration"] doubleValue] > 0) item.duration = [r[@"duration"] doubleValue];
        done([NSURL URLWithString:r[@"video"]], [NSURL URLWithString:r[@"audio"]], publishedInfo(r), nil);
    }];
}
@end
