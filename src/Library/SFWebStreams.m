#import "SFWebStreams+Private.h"
#import "SFApp.h"
#import "SFStore.h"
#import "SFEngine.h"
#import "SFMediaProxy.h"
#import "SFLoopbackClient.h"
#import "SFJSON.h"
#import "SFLibrary.h"
#import <Security/SecRandom.h>

static const NSTimeInterval kIdle = 600;            // a stream nobody read or reported for this long ends
static const NSUInteger kPerDevice = 3;             // a device's streams at once (a fourth ends the oldest)
static const NSTimeInterval kHeaderTimeout = 60;    // a track's header ranges (the engine's first SABR answer)
static const NSUInteger kHeaderPiece = 16;

static NSString *const kNotForBrowser = @"Dieses Video lässt sich im Browser nicht abspielen.";

@implementation SFWebStream
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

- (void)play:(SFItem *)item device:(NSString *)device done:(void (^)(NSDictionary *, NSInteger, NSString *))done {
    if (item.drm) { done(nil, 403, SFDRMNotice); return; }
    if (item.kind != SFItemVideo && item.kind != SFItemLive) { done(nil, 400, @"Das ist kein Video."); return; }
    Class<SFApp> app = [SFAppRegistry appForItem:item];
    NSString *ref = item.resolverRef ?: item.identifier;
    SFURLDone resolved = ^(NSURL *url, NSError *e) {
        SFMain(^{
            if (!url) { done(nil, 502, e.localizedDescription ?: @"Das Video ließ sich nicht abrufen."); return; }
            [self open:item url:url app:app device:device done:done];
        });
    };
    if ([app respondsToSelector:@selector(resolveForBrowser:done:)] && [[app refPrefixes] containsObject:SFRefPrefix(ref) ?: @""])
        [app resolveForBrowser:ref done:resolved];
    else [item resolveURL:resolved];
}

- (void)open:(SFItem *)item url:(NSURL *)url app:(Class<SFApp>)app device:(NSString *)device
        done:(void (^)(NSDictionary *, NSInteger, NSString *))done {
    SFWebStream *s = [SFWebStream new];
    s.identifier = NewID();
    s.device = device;
    s.item = item;
    s.source = SFMPVSourceFor(url) ?: @{};
    s.live = item.kind == SFItemLive || [s.source[@"live"] boolValue];
    s.lastUsed = [NSDate timeIntervalSinceReferenceDate];
    if (!s.identifier) { done(nil, 500, kNotForBrowser); return; }
    NSString *v = str(s.source[@"video"]), *a = str(s.source[@"audio"]);
    if (v && a) {   // a DASH pair: its headers decide (background: the reads wait for the engine)
        s.kind = SFWebStreamDash;
        s.video = [NSURL URLWithString:v]; s.audio = [NSURL URLWithString:a];
        s.prefixes = [@[RoutePrefix(s.video) ?: @"", RoutePrefix(s.audio) ?: @""] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        SFBackground(^{
            NSString *why = nil;
            SFFMP4Track *vt = [self trackAt:s.video why:&why], *at = vt ? [self trackAt:s.audio why:&why] : nil;
            SFMain(^{
                if (!vt || !at || !vt.isVideo || at.isVideo) {
                    SFLog(@"web: %@ is no browser stream (%@)", item.identifier, why ?: @"track kinds");
                    [self endSession:s app:app];
                    done(nil, 415, kNotForBrowser);
                    return;
                }
                s.master = SFHLSMasterPlaylist(vt, at, @"v.m3u8", @"a.m3u8");
                s.videoPlaylist = SFHLSMediaPlaylist(vt, @"t/v");
                s.audioPlaylist = SFHLSMediaPlaylist(at, @"t/a");
                [self opened:s app:app duration:vt.duration done:done];
            });
        });
        return;
    }
    NSURL *local = url;
    if (url.isFileURL) {
        s.kind = SFWebStreamLocalFile;
        s.upstream = url;
        [self opened:s app:app duration:item.duration done:done];
        return;
    }
    // a source's URL: through the media proxy (the store), as the TV's player opens it (the proxy keeps
    // its own URLs as they are); a local service's (the engine's live playlist) is served as it is
    if ([SFMediaProxy canServe:url]) {
        local = [[SFMediaProxy shared] localURLFor:url item:item.identifier];
        if (![local isEqual:url]) s.proxied = local;
    }
    if (![local.host isEqualToString:@"127.0.0.1"]) { done(nil, 415, kNotForBrowser); return; }
    NSString *ext = local.path.pathExtension.lowercaseString;
    s.kind = ([ext isEqualToString:@"m3u8"] || [ext isEqualToString:@"m3u"] || [s.source[@"hls"] boolValue]) ? SFWebStreamHLS : SFWebStreamFile;
    s.upstream = local;
    NSString *prefix = RoutePrefix(local);
    if (!prefix) { done(nil, 415, kNotForBrowser); return; }
    s.prefixes = @[prefix];
    [self opened:s app:app duration:item.duration done:done];
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

- (void)opened:(SFWebStream *)s app:(Class<SFApp>)app duration:(NSTimeInterval)duration
          done:(void (^)(NSDictionary *, NSInteger, NSString *))done {
    NSTimeInterval resume = s.live ? 0 : [[SFStore shared] positionFor:s.item.identifier];
    NSTimeInterval start = resume > 15 ? resume - 3 : 0;   // as the TV resumes (a short lead-in)
    if ([app respondsToSelector:@selector(playback:startsAt:)] && !s.live) [app playback:s.source startsAt:start];
    NSMutableArray *ended = [NSMutableArray new];
    @synchronized (self) {
        _streams[s.identifier] = s;
        NSArray *mine = [[_streams.allValues filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"device == %@", s.device]]
                         sortedArrayUsingComparator:^NSComparisonResult(SFWebStream *a, SFWebStream *b) { return [@(a.lastUsed) compare:@(b.lastUsed)]; }];
        for (NSUInteger i = 0; i + kPerDevice < mine.count; i++) { [ended addObject:mine[i]]; [_streams removeObjectForKey:[mine[i] identifier]]; }
    }
    for (SFWebStream *old in ended) { [self endSession:old app:[SFAppRegistry appForItem:old.item]]; [self ended:old why:@"the device opened another"]; }
    if (!_sweep) _sweep = [NSTimer scheduledTimerWithTimeInterval:60 target:self selector:@selector(sweep) userInfo:nil repeats:YES];
    NSString *kindName = s.kind == SFWebStreamDash || s.kind == SFWebStreamHLS ? @"hls" : @"file";
    // an HLS playlist is served at its own local path (l/<port>/<path>): relative URIs in it resolve as they do locally
    NSString *path = s.kind == SFWebStreamDash ? @"index.m3u8"
                   : s.kind == SFWebStreamHLS ? [NSString stringWithFormat:@"l/%@%@", s.upstream.port, CFBridgingRelease(CFURLCopyPath((__bridge CFURLRef)s.upstream))]
                   : [@"media" stringByAppendingString:s.upstream.path.pathExtension.length ? [@"." stringByAppendingString:s.upstream.path.pathExtension] : @""];
    SFLog(@"web: stream %@ for %@ (%@, device %@)", [s.identifier substringToIndex:6], s.item.identifier,
          @[@"dash", @"hls", @"file", @"local file"][s.kind], s.device);
    done(@{@"stream": s.identifier, @"kind": kindName, @"url": [NSString stringWithFormat:@"/m/%@/%@", s.identifier, path],
           @"start": @(start), @"duration": @(duration > 0 ? duration : 0), @"live": @(s.live), @"title": s.item.title ?: @""}, 200, nil);
}

#pragma mark Reports and lifetime

- (NSInteger)report:(NSString *)streamID device:(NSString *)device state:(NSDictionary *)state {
    SFWebStream *s = [self streamWithID:streamID];
    if (!s || (device && ![s.device isEqualToString:device])) return 404;   // nil: asked on the stream's own capability path
    NSString *st = str(state[@"state"]);
    if (![@[@"playing", @"paused", @"buffering", @"ended", @"closed"] containsObject:st ?: @""]) return 400;
    double pos = [num(state[@"position"]) doubleValue], dur = [num(state[@"duration"]) doubleValue];
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

- (void)sweep {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSMutableArray *idle = [NSMutableArray new];
    @synchronized (self) {
        for (SFWebStream *s in _streams.allValues) if (now - s.lastUsed > kIdle) [idle addObject:s];
        for (SFWebStream *s in idle) [_streams removeObjectForKey:s.identifier];
        if (!_streams.count) { [_sweep invalidate]; _sweep = nil; }
    }
    for (SFWebStream *s in idle) { [self endSession:s app:[SFAppRegistry appForItem:s.item]]; [self ended:s why:@"unused"]; }
}

- (void)ended:(SFWebStream *)s why:(NSString *)why {
    if (s.proxied) [[SFMediaProxy shared] releaseURL:s.proxied];
    SFLog(@"web: stream %@ ended (%@)", [s.identifier substringToIndex:6], why);
}

// the app's side of a stream that ends without the browser's "closed" (its view is over)
- (void)endSession:(SFWebStream *)s app:(Class<SFApp>)app {
    if ([app respondsToSelector:@selector(playback:reports:)]) [app playback:s.source reports:@{@"state": @"closed"}];
}
@end
