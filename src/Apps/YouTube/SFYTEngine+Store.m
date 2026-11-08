// SFYTEngine (Store) - the engine's sessions and the media store (docs/media-store.md).
//
// Every session Sofa serves has a table entry: its video, and per local track key (video, audio,
// an audio key, subs:<key>) the track's identity across sessions, length and type. Engine sessions
// get theirs from the open answer; the media routes (SFYTEngine+Media.m) serve what the store holds
// from disk and write what the engine delivers.
//
// An opened VOD session leaves its item's manifest in the store: what playing it needs without the
// engine. When the manifest's video and main audio are complete on disk, open() answers with a
// stored session - the same answer shape, the same local routes, Sofa serves it alone (no engine,
// no YouTube request, also offline). Subtitles go to the store as small tracks of their own.
#import "SFModel.h"
#import "SFYTEngine+Private.h"
#import "SFJSON.h"
#import "SFDownloads.h"
#import "SFMediaStore.h"

static const NSUInteger kSessions = 32;   // table entries kept (the newest; older ones are long closed)

// sid -> {vid, stored, tracks: {key -> {id, total, mimeType}}}; any queue, under the lock
static NSMutableDictionary *gSessions;
static NSMutableArray *gOrder;
static NSObject *gLock;

static void Locked(dispatch_block_t b) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gLock = [NSObject new]; gSessions = [NSMutableDictionary new]; gOrder = [NSMutableArray new]; });
    @synchronized (gLock) { b(); }
}

static SFMediaStore *Store(void) { return [SFDownloads shared].mediaStore; }
static NSString *ItemOf(NSString *vid) { return [@"yt:" stringByAppendingString:vid]; }
static NSString *SubsKey(NSString *key) { return [@"subs:" stringByAppendingString:key]; }

// the last path part of a local URL, decoded (".../audio/251%3Aen" -> "251:en")
static NSString *LastPart(NSString *url) {
    NSString *p = [[url componentsSeparatedByString:@"/"] lastObject];
    return p.length ? [p stringByRemovingPercentEncoding] : nil;
}
// as the engine's encodeURIComponent: a key stays one path part
static NSString *Enc(NSString *s) {
    static NSCharacterSet *ok;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ok = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"]; });
    return [s stringByAddingPercentEncodingWithAllowedCharacters:ok] ?: s;
}

@implementation SFYTEngine (Store)

#pragma mark Session table

- (void)noteSession:(NSString *)sid video:(NSString *)vid stored:(BOOL)stored tracks:(NSDictionary *)tracks {
    if (!sid.length) return;
    Locked(^{
        NSMutableDictionary *s = gSessions[sid];
        if (!s) {
            s = [@{@"tracks": [NSMutableDictionary new]} mutableCopy];
            gSessions[sid] = s; [gOrder addObject:sid];
            while (gOrder.count > kSessions) { [gSessions removeObjectForKey:gOrder[0]]; [gOrder removeObjectAtIndex:0]; }
        }
        if (vid.length) s[@"vid"] = vid;
        if (stored) s[@"stored"] = @YES;
        [s[@"tracks"] addEntriesFromDictionary:tracks ?: @{}];
    });
}

- (NSDictionary *)trackInfo:(NSString *)key session:(NSString *)sid {
    __block NSDictionary *t;
    Locked(^{ t = dict(gSessions[sid][@"tracks"][key]); });
    return t;
}

- (BOOL)isStoredSession:(NSString *)sid {
    __block BOOL st;
    Locked(^{ st = [gSessions[sid][@"stored"] boolValue]; });
    return st;
}

- (NSString *)videoOfSession:(NSString *)sid {
    __block NSString *v;
    Locked(^{ v = str(gSessions[sid][@"vid"]); });
    return v;
}

#pragma mark Manifests

// An engine VOD answer: its table entry, and the item's manifest - the fields a stored session
// answers with, the tracks as identities (no session, no URL)
- (void)noteOpened:(NSDictionary *)j {
    NSString *vid = str(j[@"id"]), *sid = str(j[@"sid"]);
    NSDictionary *tracks = dict(j[@"tracks"]);
    [self noteSession:sid video:vid stored:NO tracks:tracks];
    NSString *akey = LastPart(str(j[@"audio"]));
    if (!vid.length || j[@"hls"] || !dict(tracks[@"video"]) || !akey || !dict(tracks[akey])) return;   // lives: nothing to keep
    NSMutableDictionary *m = [NSMutableDictionary new];
    for (NSString *k in @[@"title", @"duration", @"height", @"fps", @"vcodec", @"acodec", @"alang", @"vitag", @"aitag", @"endscreen", @"published"])
        if (j[k] && j[k] != [NSNull null]) m[k] = j[k];
    m[@"video"] = tracks[@"video"];
    m[@"audioKey"] = akey;
    m[@"audio"] = tracks[akey];
    for (NSDictionary *a in [j[@"audios"] isKindOfClass:[NSArray class]] ? j[@"audios"] : @[])
        if ([LastPart(str(a[@"url"])) isEqualToString:akey]) { m[@"audioName"] = str(a[@"name"]) ?: @""; m[@"original"] = a[@"original"] ?: @YES; }
    NSMutableArray *subs = [NSMutableArray new];
    for (NSDictionary *s in [j[@"subs"] isKindOfClass:[NSArray class]] ? j[@"subs"] : @[]) {
        NSString *file = LastPart(str(s[@"url"]));
        if (![file hasSuffix:@".vtt"]) continue;
        NSString *key = [file substringToIndex:file.length - 4];
        [subs addObject:@{@"key": key, @"lang": str(s[@"lang"]) ?: @"", @"kind": str(s[@"kind"]) ?: @"", @"name": str(s[@"name"]) ?: @"",
                          @"id": [NSString stringWithFormat:@"yt:%@:subs:%@", vid, key]}];
        [self noteSession:sid video:vid stored:NO tracks:@{SubsKey(key): @{@"id": subs.lastObject[@"id"], @"total": @0, @"mimeType": @"text/vtt"}}];
    }
    m[@"subs"] = subs;
    [Store() setManifest:m forItem:ItemOf(vid)];
}

// The stored session of a video whose video and main audio are complete on disk; nil otherwise.
- (NSDictionary *)storedAnswer:(NSString *)vid {
    NSDictionary *m = vid.length ? [Store() manifestOf:ItemOf(vid)] : nil;
    NSDictionary *v = dict(m[@"video"]), *a = dict(m[@"audio"]);
    NSString *akey = str(m[@"audioKey"]), *base = self.mediaBase;
    if (!v || !a || !akey || !base || ![Store() hasComplete:@[str(v[@"id"]) ?: @"", str(a[@"id"]) ?: @""]]) return nil;
    NSString *sid = [@"st-" stringByAppendingString:[[[NSUUID UUID] UUIDString] substringToIndex:8].lowercaseString];
    NSString *u = [NSString stringWithFormat:@"%@/s/%@", base, sid];
    NSMutableDictionary *tracks = [@{@"video": v, @"audio": a, akey: a} mutableCopy];
    NSMutableArray *subs = [NSMutableArray new];
    for (NSDictionary *s in [m[@"subs"] isKindOfClass:[NSArray class]] ? m[@"subs"] : @[]) {
        NSString *sk = str(s[@"key"]), *sidOfSub = str(s[@"id"]);
        SFExtentSet *have = [Store() extentsOf:sidOfSub ?: @""];
        if (!sk || !have.bytes || ![Store() hasComplete:@[sidOfSub]]) continue;   // a subtitle never fetched: not offered
        tracks[SubsKey(sk)] = @{@"id": sidOfSub, @"total": @(have.bytes), @"mimeType": @"text/vtt"};
        [subs addObject:@{@"lang": s[@"lang"] ?: @"", @"kind": s[@"kind"] ?: @"", @"name": s[@"name"] ?: @"",
                          @"url": [NSString stringWithFormat:@"%@/subs/%@.vtt", u, Enc(sk)]}];
    }
    [self noteSession:sid video:vid stored:YES tracks:tracks];
    NSMutableDictionary *r = [NSMutableDictionary new];
    for (NSString *k in @[@"title", @"duration", @"height", @"fps", @"vcodec", @"acodec", @"alang", @"vitag", @"aitag", @"published"]) if (m[k]) r[k] = m[k];
    NSString *aurl = [NSString stringWithFormat:@"%@/audio/%@", u, Enc(akey)];
    [r addEntriesFromDictionary:@{@"id": vid, @"sid": sid, @"live": @NO, @"stored": @YES, @"cached": @NO, @"secs": @0,
                                  @"video": [u stringByAppendingString:@"/video"], @"audio": aurl,
                                  @"audios": @[@{@"lang": m[@"alang"] ?: @"", @"url": aurl, @"original": m[@"original"] ?: @YES, @"dubbed": @NO,
                                                 @"described": @NO, @"name": m[@"audioName"] ?: @"", @"itag": m[@"aitag"] ?: @0, @"acodec": m[@"acodec"] ?: @""}],
                                  @"subs": subs, @"endscreen": m[@"endscreen"] ?: @[], @"tracks": tracks}];
    return r;
}

- (BOOL)canOpen:(NSString *)vid { return self.available || [self storedAnswer:vid] != nil; }

- (BOOL)openStored:(NSString *)vid done:(void (^)(NSDictionary *, NSError *))done {
    NSDictionary *r = [self storedAnswer:vid];
    if (!r) return NO;
    SFLog(@"yt-engine: opened %@ -> %@p%@ %@/%@ from the media store", vid, r[@"height"], r[@"fps"], r[@"vcodec"], r[@"acodec"]);
    done(r, nil);
    return YES;
}

#pragma mark Subtitles

// A session's subtitle text: from the store, else from the engine (then kept for the next time)
- (void)subtitles:(NSString *)key session:(NSString *)sid done:(void (^)(NSString *vtt, NSError *e))done {
    NSDictionary *t = [self trackInfo:SubsKey(key) session:sid];
    NSString *tid = str(t[@"id"]);
    SFExtentSet *have = tid ? [Store() extentsOf:tid] : nil;
    NSData *d = have.bytes && [Store() hasComplete:@[tid]] ? [Store() read:tid start:0 length:(NSUInteger)have.bytes] : nil;
    if (d) { done([[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding], nil); return; }
    if ([self isStoredSession:sid]) { done(nil, [NSError errorWithDomain:@"SFYTEngine" code:404 userInfo:@{NSLocalizedDescriptionKey: @"not stored"}]); return; }
    [self request:@"subtitles" args:@[sid, key] timeout:30 done:^(id v, NSError *e) {
        NSString *vtt = str(v);
        NSData *bytes = [vtt dataUsingEncoding:NSUTF8StringEncoding];
        NSString *vid = [self videoOfSession:sid];
        if (bytes.length && tid && vid) [Store() write:bytes key:tid item:ItemOf(vid) kind:@"subs" total:(long long)bytes.length at:0];
        done(vtt, vtt ? nil : (e ?: [NSError errorWithDomain:@"SFYTEngine" code:502 userInfo:@{NSLocalizedDescriptionKey: @"no text"}]));
    }];
}
@end
