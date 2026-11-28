#import "SFWebStreams+Private.h"
#import "SFApp.h"
#import "SFStore.h"
#import "SFEngine.h"
#import "SFMediaProxy.h"
#import "SFLoopbackClient.h"
#import "SFJSON.h"
#import "SFLibrary.h"
#import "SFDownloads.h"
#import "SFMediaStore.h"
#import "SFWebErrors.h"
#import <Security/SecRandom.h>

// A stream nobody read or reported for this long ends: the client is gone without saying so (closed
// tab, killed app). One that said "paused" is not gone - it waits for its viewer (background audio,
// picture in picture, the phone put away during a call or a meal): it is kept for an evening, after which
// a paused stream is a forgotten one (iOS ends a suspended app without a word). While it waits it holds
// little: no segmenter job runs (they stop after 45 s), its made segments are dropped once it is idle
// past the first limit, and an app session behind it ends by the app's own rule (YouTube's engine closes
// an unused session after 10 minutes, as on the TV) - the stream ends with it. Either way the client
// plays the item again at its position on 404/410 (docs/api.md "Streams"). Dev: SOFA_STREAM_IDLE/_PAUSED.
static NSTimeInterval IdleLimit(void) { return SFDevSeconds(@"SOFA_STREAM_IDLE", 600); }
static NSTimeInterval PausedLimit(void) { return SFDevSeconds(@"SOFA_STREAM_PAUSED", 4 * 3600); }
static const NSUInteger kPerDevice = 3;             // a device's streams at once (a fourth ends the oldest)
static const NSTimeInterval kHeaderTimeout = 60;    // a track's header ranges (the engine's first SABR answer)
static const NSUInteger kHeaderPiece = 16;

static NSString *const kNotForBrowser = @"Dieses Video lässt sich im Browser nicht abspielen.";

NSDictionary *SFWebStreamReportError(NSInteger status) {
    return status == 400 ? SFWebError(SFWebErrBadState, @"Unbekannter Zustand.") : SFWebError(SFWebErrStreamGone, @"Diese Wiedergabe ist beendet.");
}

@implementation SFWebStream {
    NSTimeInterval _waitingSince;  // "buffering" began (0: not buffering)
}

- (NSString *)waitedFor:(NSString *)state position:(double)position {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSString *line = nil;
    if ([state isEqualToString:@"buffering"]) { if (!_waitingSince) _waitingSince = now; return nil; }
    if (![state isEqualToString:@"playing"]) { _waitingSince = 0; return nil; }
    if (!self.everPlayed)
        line = [NSString stringWithFormat:@"plays after %.1f s at %.0f s", now - self.opened, position];
    else if (_waitingSince)
        line = [NSString stringWithFormat:@"plays on after %.1f s of buffering at %.0f s", now - _waitingSince, position];
    self.everPlayed = YES;
    _waitingSince = 0;
    return line;
}
@end

// "http://127.0.0.1:<port>/<a>/<b>/" - the route a local URL belongs to (a proxy or engine session)
static NSString *RoutePrefix(NSURL *u) {
    NSArray *p = u.pathComponents;   // "/", a, b, ...
    if (![u.host isEqualToString:@"127.0.0.1"] || p.count < 3) return nil;
    return [NSString stringWithFormat:@"http://127.0.0.1:%@/%@/%@/", u.port, p[1], p[2]];
}

static NSString *NewID(void) {
    uint8_t b[16];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof b, b) != 0) return nil;
    NSMutableString *s = [NSMutableString new];
    for (int i = 0; i < 16; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

@implementation SFWebStreams {
    NSMutableDictionary *_streams;   // id -> SFWebStream (guarded by self)
    NSTimer *_sweep;
    NSMutableSet *_observed;         // apps' session-lost notifications observed (main thread)
}

+ (instancetype)shared {
    static SFWebStreams *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [SFWebStreams new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) _streams = [NSMutableDictionary new];
    return self;
}

- (NSUInteger)countForTesting { @synchronized (self) { return _streams.count; } }

- (SFWebStream *)streamWithID:(NSString *)identifier {
    SFWebStream *s;
    @synchronized (self) { s = identifier ? _streams[identifier] : nil; }
    s.lastUsed = [NSDate timeIntervalSinceReferenceDate];
    return s;
}

#pragma mark Opening

// A codec string's sample entry ("avc1.64002a" -> "avc1", "mp4a.40.2" -> "mp4a"), as SFAVBrowserCodec names it
static NSString *Tag(NSString *codec) { return [[codec componentsSeparatedByString:@"."].firstObject lowercaseString]; }

- (void)play:(SFItem *)item device:(NSString *)device formats:(NSArray *)order done:(void (^)(NSDictionary *, NSInteger, NSString *, NSString *))done {
    if (item.drm) { done(nil, 403, SFWebErrDRM, SFDRMNotice); return; }
    if (item.kind != SFItemVideo && item.kind != SFItemLive) { done(nil, 400, SFWebErrNotVideo, @"Das ist kein Video."); return; }
    NSSet *formats = [NSSet setWithArray:order];
    Class<SFApp> app = [SFAppRegistry appForItem:item];
    NSString *ref = item.resolverRef ?: item.identifier;
    SFURLDone (^resolved)(dispatch_block_t) = ^SFURLDone(dispatch_block_t fallback) {
        return ^(NSURL *url, NSError *e) {
            SFMain(^{
                if (url) { [self open:item url:url app:app device:device formats:formats fallback:fallback done:done]; return; }
                if (fallback) { fallback(); return; }
                done(nil, 502, SFWebErrUpstream, e.localizedDescription ?: @"Das Video ließ sich nicht abrufen.");
            });
        };
    };
    if (![app respondsToSelector:@selector(resolveForBrowser:formats:done:)] || ![[app refPrefixes] containsObject:SFRefPrefix(ref) ?: @""]) {
        [item resolveURL:resolved(nil)];
        return;
    }
    dispatch_block_t online = ^{ [app resolveForBrowser:ref formats:order done:resolved(nil)]; };
    // an app with a browser format of its own (YouTube: an H.264 session) - but a copy complete in the media
    // store plays from there (the segmenter makes it playable, docs/pwa.md §8); online if that can't be
    if ([[SFDownloads shared].mediaStore itemIsComplete:item.identifier]) [item resolveURL:resolved(online)];
    else online();
}

- (void)open:(SFItem *)item url:(NSURL *)url app:(Class<SFApp>)app device:(NSString *)device formats:(NSSet *)formats
    fallback:(dispatch_block_t)fallback done:(void (^)(NSDictionary *, NSInteger, NSString *, NSString *))done {
    SFWebStream *s = [SFWebStream new];
    s.identifier = NewID();
    s.device = device;
    s.item = item;
    s.source = SFMPVSourceFor(url) ?: @{};
    s.live = item.kind == SFItemLive || [s.source[@"live"] boolValue];
    s.lastUsed = s.opened = [NSDate timeIntervalSinceReferenceDate];
    if (!s.identifier) { done(nil, 500, SFWebErrInternal, kNotForBrowser); return; }
    // what can't be: the fallback (the app's browser format) or the viewer is told
    void (^cannot)(NSString *) = ^(NSString *message) {
        [self endSession:s app:app];
        if (fallback) fallback();
        else done(nil, 415, [message isEqualToString:SFWebTranscodeBusyMessage] ? SFWebErrEncoderBusy : SFWebErrNotPlayable, message ?: kNotForBrowser);
    };
    NSString *v = str(s.source[@"video"]), *a = str(s.source[@"audio"]);
    if (v && a) { [self openPair:s video:v audio:a app:app formats:formats cannot:cannot done:done]; return; }
    BOOL stored = url.isFileURL || [s.source[@"stored"] boolValue];
    NSURL *local = url;
    if (url.isFileURL) {
        s.kind = SFWebStreamLocalFile;
        s.upstream = url;
    } else {
        // a source's URL: through the media proxy (the store), as the TV's player opens it (the proxy keeps
        // its own URLs as they are); a local service's (the engine's live playlist) is served as it is
        if ([SFMediaProxy canServe:url]) {
            local = [[SFMediaProxy shared] localURLFor:url item:item.identifier];
            if (![local isEqual:url]) s.proxied = local;
        }
        if (![local.host isEqualToString:@"127.0.0.1"]) { cannot(nil); return; }
        NSString *ext = local.path.pathExtension.lowercaseString;
        s.kind = ([ext isEqualToString:@"m3u8"] || [ext isEqualToString:@"m3u"] || [s.source[@"hls"] boolValue]) ? SFWebStreamHLS : SFWebStreamFile;
        s.upstream = local;
        NSString *prefix = RoutePrefix(local);
        if (!prefix) { cannot(nil); return; }
        s.prefixes = @[prefix];
    }
    // on demand (a mediathek's MP4 or HLS, online or downloaded) for a browser decoding AV1: re-encoded
    // into it - less than half the bytes over the viewer's line (docs/pwa.md §8); as before when that can't be
    NSString *reencode = !s.live && [formats containsObject:@"av01"] ? @"av01" : nil;
    if (s.kind == SFWebStreamHLS && reencode) {
        [self reencodeHLS:s formats:formats done:^(BOOL segmented) {
            [self opened:s app:app duration:segmented ? s.transcode.duration : item.duration done:done];
        }];
        return;
    }
    if (s.kind == SFWebStreamHLS || s.live || (!stored && !reencode)) { [self opened:s app:app duration:item.duration done:done]; return; }
    // a stored file: as it is where the browser plays it (an MP4 of its codecs), else through the segmenter
    NSString *input = url.isFileURL ? url.path : local.absoluteString;
    [self segment:s video:input audio:nil keyframes:nil formats:formats reencode:reencode done:^(BOOL segmented, BOOL asIs, NSString *why) {
        if (!segmented && !asIs) SFLog(@"web: %@ as it is (%@)", item.identifier, why);
        [self opened:s app:app duration:segmented ? s.transcode.duration : item.duration done:done];
    }];
}

// A DASH pair: the browser reads the tracks' byte ranges itself where they are fragmented MP4 of codecs it
// decodes (YouTube's browser session: H.264 or AV1 + AAC); else the segmenter (a stored video's WebM, Opus)
- (void)openPair:(SFWebStream *)s video:(NSString *)v audio:(NSString *)a app:(Class<SFApp>)app formats:(NSSet *)formats
          cannot:(void (^)(NSString *))cannot done:(void (^)(NSDictionary *, NSInteger, NSString *, NSString *))done {
    s.video = [NSURL URLWithString:v]; s.audio = [NSURL URLWithString:a];
    s.prefixes = [@[RoutePrefix(s.video) ?: @"", RoutePrefix(s.audio) ?: @""] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    SFBackground(^{   // its headers decide (the reads wait for the engine)
        NSString *why = nil;
        SFFMP4Track *vt = [self trackAt:s.video why:&why], *at = vt ? [self trackAt:s.audio why:&why] : nil;
        SFMain(^{
            BOOL pair = vt && at && vt.isVideo && !at.isVideo;
            void (^byRanges)(void) = ^{
                s.kind = SFWebStreamDash;
                s.master = SFHLSMasterPlaylist(vt, at, @"v.m3u8", @"a.m3u8");
                s.videoPlaylist = SFHLSMediaPlaylist(vt, @"t/v");
                s.audioPlaylist = SFHLSMediaPlaylist(at, @"t/a");
                [self opened:s app:app duration:vt.duration done:done];
            };
            if (pair && [formats containsObject:Tag(vt.codec)] && [formats containsObject:Tag(at.codec)]) { byRanges(); return; }
            NSMutableArray *keys = nil;   // a fragmented MP4's subsegments start at keyframes (its sidx)
            if (vt) { keys = [NSMutableArray new]; double t = 0; for (NSArray *seg in vt.segments) { [keys addObject:@(t)]; t += [seg[2] doubleValue]; } }
            [self segment:s video:v audio:a keyframes:keys formats:formats reencode:nil done:^(BOOL segmented, BOOL asIs, NSString *why2) {
                if (segmented) { [self opened:s app:app duration:s.transcode.duration done:done]; return; }
                SFLog(@"web: %@ - no segments (%@; the browser decodes %@)", s.item.identifier, why2 ?: why ?: @"?",
                      [[formats.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@" "]);
                if (pair) byRanges();   // the browser says itself what it can't decode
                else cannot([why2 isEqualToString:SFWebTranscodeBusyMessage] ? why2 : nil);
            }];
        });
    });
}

// A track's header (moov, sidx) through its route: small reads within the init (what the engine has
// after its first SABR answer) - never past it, so no media is asked for that the player won't read.
- (SFFMP4Track *)trackAt:(NSURL *)u why:(NSString **)why {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:kHeaderTimeout];
    return [SFFMP4Track trackWithReader:^NSData *(long long off, NSUInteger len) {
        NSTimeInterval left = [until timeIntervalSinceNow];
        if (left <= 0) return nil;
        SFLoopbackResponse *r = [SFLoopbackClient get:u range:[NSString stringWithFormat:@"bytes=%lld-%lld", off, off + (long long)MAX(len, kHeaderPiece) - 1] timeout:left];
        if (r.status != 206 && r.status != 200) { SFLog(@"web: header range %lld+%lu of %@ answered %ld", off, (unsigned long)len, u.path, (long)r.status); return nil; }
        return r.body.length > len ? [r.body subdataWithRange:NSMakeRange(0, len)] : r.body;
    } error:why];
}

- (double)startOf:(SFWebStream *)s {
    NSTimeInterval resume = s.live ? 0 : [[SFStore shared] positionFor:s.item.identifier];
    return resume > 15 ? resume - 3 : 0;   // as the TV resumes (a short lead-in)
}

- (void)opened:(SFWebStream *)s app:(Class<SFApp>)app duration:(NSTimeInterval)duration
          done:(void (^)(NSDictionary *, NSInteger, NSString *, NSString *))done {
    NSTimeInterval start = [self startOf:s];
    if ([app respondsToSelector:@selector(playback:startsAt:)] && !s.live) [app playback:s.source startsAt:start];
    NSMutableArray *ended = [NSMutableArray new];
    @synchronized (self) {
        _streams[s.identifier] = s;
        NSArray *mine = [[_streams.allValues filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"device == %@", s.device]]
                         sortedArrayUsingComparator:^NSComparisonResult(SFWebStream *a, SFWebStream *b) { return [@(a.lastUsed) compare:@(b.lastUsed)]; }];
        for (NSUInteger i = 0; i + kPerDevice < mine.count; i++) { [ended addObject:mine[i]]; [_streams removeObjectForKey:[mine[i] identifier]]; }
    }
    for (SFWebStream *old in ended) { [self endSession:old app:[SFAppRegistry appForItem:old.item]]; [self ended:old why:@"the device opened another"]; }
    if (!_sweep) _sweep = [NSTimer scheduledTimerWithTimeInterval:MIN(60, IdleLimit() / 2) target:self selector:@selector(sweep) userInfo:nil repeats:YES];
    [self observeSessionsOf:app];
    NSString *kindName = s.kind == SFWebStreamDash || s.kind == SFWebStreamHLS || s.kind == SFWebStreamSegmented ? @"hls" : @"file";
    // an HLS playlist is served at its own local path (l/<port>/<path>): relative URIs in it resolve as they do locally
    NSString *path = s.kind == SFWebStreamDash || s.kind == SFWebStreamSegmented ? @"index.m3u8"
                   : s.kind == SFWebStreamHLS ? [NSString stringWithFormat:@"l/%@%@", s.upstream.port, CFBridgingRelease(CFURLCopyPath((__bridge CFURLRef)s.upstream))]
                   : [@"media" stringByAppendingString:s.upstream.path.pathExtension.length ? [@"." stringByAppendingString:s.upstream.path.pathExtension] : @""];
    SFLog(@"web: stream %@ for %@ (%@, device %@)", [s.identifier substringToIndex:6], s.item.identifier,
          s.transcode ? [@"segments " stringByAppendingString:s.transcode.mode] : @[@"dash", @"hls", @"file", @"local file", @"segments"][s.kind], s.device);
    NSMutableDictionary *answer = [@{@"stream": s.identifier, @"kind": kindName, @"url": [NSString stringWithFormat:@"/m/%@/%@", s.identifier, path],
           @"start": @(start), @"duration": @(duration > 0 ? duration : 0), @"live": @(s.live), @"title": s.item.title ?: @""} mutableCopy];
    if (s.transcode) answer[@"segmented"] = s.transcode.mode;   // what the segmenter does (diagnostics)
    done(answer, 200, nil, nil);
}

#pragma mark Reports and lifetime

- (NSInteger)report:(NSString *)streamID device:(NSString *)device state:(NSDictionary *)state {
    SFWebStream *s = [self streamWithID:streamID];
    if (!s || (device && ![s.device isEqualToString:device])) return 404;   // nil: asked on the stream's own capability path
    NSString *st = str(state[@"state"]);
    if (![@[@"playing", @"paused", @"buffering", @"ended", @"closed"] containsObject:st ?: @""]) return 400;
    s.paused = [st isEqualToString:@"paused"];
    double pos = [num(state[@"position"]) doubleValue], dur = [num(state[@"duration"]) doubleValue];
    NSString *waited;
    @synchronized (s) { waited = [s waitedFor:st position:pos]; }
    if (waited) SFLog(@"web: stream %@ %@", [s.identifier substringToIndex:6], waited);
    Class<SFApp> app = [SFAppRegistry appForItem:s.item];
    if ([app respondsToSelector:@selector(playback:reports:)]) {
        NSMutableDictionary *r = [@{@"state": st} mutableCopy];
        if (![st isEqualToString:@"closed"]) r[@"position"] = @(MAX(0, pos));
        if (num(state[@"lactMs"])) r[@"lactMs"] = state[@"lactMs"];
        [app playback:s.source reports:r];
    }
    if (!s.live && dur > 0 && (pos > 0 || [st isEqualToString:@"ended"])) {
        BOOL wasWatched = [[SFStore shared] watched:s.item.identifier];
        if ([st isEqualToString:@"ended"]) pos = dur;
        [[SFStore shared] savePosition:pos duration:dur forItem:s.item];
        // the TV's pages follow what they list (Weiterschauen, watched marks) - on what changes them,
        // not on every periodic report (Home would rebuild every few seconds)
        BOOL first = !s.everSaved;
        s.everSaved = YES;
        if (first || [st isEqualToString:@"ended"] || [st isEqualToString:@"closed"] || wasWatched != [[SFStore shared] watched:s.item.identifier])
            [[NSNotificationCenter defaultCenter] postNotificationName:SFLibraryDidChangeNotification object:nil];
    }
    if ([st isEqualToString:@"closed"]) {
        @synchronized (self) { [_streams removeObjectForKey:s.identifier]; }
        [self ended:s why:@"closed by the browser"];
    }
    return 200;
}

- (NSUInteger)endItem:(NSString *)identifier device:(NSString *)device why:(NSString *)why {
    NSMutableArray *gone = [NSMutableArray new];
    @synchronized (self) {
        for (SFWebStream *s in _streams.allValues)
            if ([s.item.identifier isEqualToString:identifier] && [s.device isEqualToString:device]) [gone addObject:s];
        for (SFWebStream *s in gone) [_streams removeObjectForKey:s.identifier];
    }
    for (SFWebStream *s in gone) { [self endSession:s app:[SFAppRegistry appForItem:s.item]]; [self ended:s why:why]; }
    return gone.count;
}

- (void)sweepForTesting { [self sweep]; }

- (void)sweep {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate], idleLimit = IdleLimit(), pausedLimit = PausedLimit();
    NSMutableArray *idle = [NSMutableArray new], *waiting = [NSMutableArray new];
    @synchronized (self) {
        for (SFWebStream *s in _streams.allValues) {
            NSTimeInterval unused = now - s.lastUsed;
            if (unused > (s.paused ? MAX(pausedLimit, idleLimit) : idleLimit)) [idle addObject:s];
            else if (unused > idleLimit) [waiting addObject:s];
        }
        for (SFWebStream *s in idle) [_streams removeObjectForKey:s.identifier];
        if (!_streams.count) { [_sweep invalidate]; _sweep = nil; }
    }
    for (SFWebStream *s in waiting) [s.transcode dropSegments];   // a paused stream holds no made segments meanwhile
    for (SFWebStream *s in idle) { [self endSession:s app:[SFAppRegistry appForItem:s.item]]; [self ended:s why:s.paused ? @"paused too long" : @"unused"]; }
}

// An app session behind streams ended (YouTube: the engine closed an unused one, or its page reloaded):
// those streams end with it - their media would fail; the client plays the item again (410)
- (void)observeSessionsOf:(Class<SFApp>)app {
    if (![app respondsToSelector:@selector(playbackSessionLostNotification)]) return;
    NSString *name = [app playbackSessionLostNotification];
    if (!name || [_observed containsObject:name]) return;
    if (!_observed) _observed = [NSMutableSet new];
    [_observed addObject:name];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionsLost:) name:name object:nil];
}

- (void)sessionsLost:(NSNotification *)n {
    NSMutableArray *gone = [NSMutableArray new];
    @synchronized (self) {
        for (SFWebStream *s in _streams.allValues) {
            Class<SFApp> app = [SFAppRegistry appForItem:s.item];
            if (![app respondsToSelector:@selector(playbackSessionLostNotification)] || ![[app playbackSessionLostNotification] isEqualToString:n.name]) continue;
            if (![app respondsToSelector:@selector(playbackIsSession:)] || ![app playbackIsSession:s.source]) continue;
            if ([app respondsToSelector:@selector(playback:lostIn:)] && ![app playback:s.source lostIn:n]) continue;
            [gone addObject:s];
        }
        for (SFWebStream *s in gone) [_streams removeObjectForKey:s.identifier];
    }
    for (SFWebStream *s in gone) [self ended:s why:@"its app session ended"];
}

- (void)ended:(SFWebStream *)s why:(NSString *)why {
    if (s.proxied) [[SFMediaProxy shared] releaseURL:s.proxied];
    [s.transcode close];
    SFLog(@"web: stream %@ ended (%@)", [s.identifier substringToIndex:6], why);
}

// the app's side of a stream that ends without the browser's "closed" (its view is over)
- (void)endSession:(SFWebStream *)s app:(Class<SFApp>)app {
    if ([app respondsToSelector:@selector(playback:reports:)]) [app playback:s.source reports:@{@"state": @"closed"}];
}
@end
