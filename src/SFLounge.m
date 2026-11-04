#import "SFLounge.h"
#import "SFCurl.h"
#import "SFStore.h"
#import "SFModel.h"
#import "SFPlayerScreen.h"
#import "SFVolume.h"
#import <curl/curl.h>

NSString *const SFLoungeRemotesDidChangeNotification = @"SFLoungeRemotesDidChangeNotification";
static NSString *const kAPI = @"https://www.youtube.com/api/lounge";
static NSString *const kScreenName = @"Sofa";   // ASCII halten (Doppel-Escape bei Sonderzeichen)

static NSString *formEncode(NSString *s) {
    return (__bridge_transfer NSString *)CFURLCreateStringByAddingPercentEscapes(NULL, (__bridge CFStringRef)(s ?: @""), NULL,
        CFSTR(":/?#[]@!$&'()*+,;=\" %<>{}|\\^`"), kCFStringEncodingUTF8);
}
static NSString *formBody(NSArray *pairs) {   // @[@[k,v], …] (Reihenfolge bleibt)
    NSMutableArray *a = [NSMutableArray new];
    for (NSArray *p in pairs) [a addObject:[NSString stringWithFormat:@"%@=%@", formEncode(p[0]), formEncode(p[1])]];
    return [a componentsJoinedByString:@"&"];
}
static NSString *zx(void) {
    static const char cs[] = "abcdefghijklmnopqrstuvwxyz0123456789";
    char b[13]; for (int i = 0; i < 12; i++) b[i] = cs[arc4random_uniform(36)]; b[12] = 0;
    return @(b);
}
static NSString *fmtTime(double t) { return [NSString stringWithFormat:@"%.3f", (isnan(t) || t < 0) ? 0 : t]; }

#pragma mark - Long-Poll (libcurl, eigener Thread)

typedef struct { void *self; } SFLPCtx;
static size_t lpWrite(char *ptr, size_t size, size_t n, void *ud);

@interface SFLounge ()
- (void)feed:(NSData *)d;
@end

@implementation SFLounge {
    dispatch_queue_t _q;            // Sitzungszustand + Senden (seriell)
    NSString *_screenID, *_deviceID, *_token;
    NSString *_sid, *_gsid;
    NSInteger _aid, _rid, _ofs;
    NSMutableData *_frameBuf;
    NSMutableDictionary *_remotes;  // id -> name
    BOOL _running;
    NSUInteger _loopGen;
    NSDate *_lastAlive;
    NSString *_cpn;
    NSTimer *_tick;
    SFPlaybackState _lastState;
    NSString *_lastVideo;
}

+ (instancetype)shared {
    static SFLounge *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [SFLounge new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _q = dispatch_queue_create("sofa.lounge", DISPATCH_QUEUE_SERIAL);
        _remotes = [NSMutableDictionary new];
        _aid = -1;
        _lastState = SFPlaybackIdle;
        _cpn = [self newCPN];
    }
    return self;
}

- (NSString *)newCPN {
    static const char cs[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    char b[17]; for (int i = 0; i < 16; i++) b[i] = cs[arc4random_uniform(64)]; b[16] = 0;
    return @(b);
}

- (NSArray *)remoteNames { @synchronized (_remotes) { return [_remotes.allValues sortedArrayUsingSelector:@selector(compare:)]; } }
- (BOOL)online { return _sid != nil; }

#pragma mark Identität / Token

- (NSString *)key:(NSString *)k { return [@"lounge." stringByAppendingString:k]; }

- (NSData *)http:(NSString *)method url:(NSString *)url body:(NSString *)body status:(NSInteger *)st {
    NSError *e = nil;
    NSDictionary *h = body ? @{@"Content-Type": @"application/x-www-form-urlencoded"} : nil;
    NSData *d = SFCurlFetch(url, method, h, [body dataUsingEncoding:NSUTF8StringEncoding], st, &e);
    if (e) SFLog(@"lounge: %@ %@ -> %@", method, ((NSString *)[url componentsSeparatedByString:@"?"][0]).lastPathComponent, e.localizedDescription);
    return d;
}

- (BOOL)ensureIdentity {   // auf _q
    SFStore *st = [SFStore shared];
    _deviceID = [st setting:[self key:@"deviceId"]];
    if (!_deviceID) { _deviceID = [[[NSUUID UUID] UUIDString] lowercaseString]; [st setSetting:_deviceID forKey:[self key:@"deviceId"]]; }
    _screenID = [st setting:[self key:@"screenId"]];
    if (!_screenID.length) {   // leer = „alle Handys getrennt“ -> neue screenId
        NSInteger code = 0;
        NSData *d = [self http:@"GET" url:[kAPI stringByAppendingString:@"/pairing/generate_screen_id"] body:nil status:&code];
        NSString *s = [[[NSString alloc] initWithData:d ?: [NSData data] encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (code != 200 || s.length < 10 || s.length > 64) return NO;
        _screenID = s;
        [st setSetting:s forKey:[self key:@"screenId"]];
    }
    _token = [st setting:[self key:@"token"]];
    double refreshAt = [[st setting:[self key:@"tokenRefresh"]] doubleValue];
    if (!_token.length || [[NSDate date] timeIntervalSince1970] > refreshAt) return [self refreshToken];
    return YES;
}

- (BOOL)refreshToken {     // auf _q
    NSInteger code = 0;
    NSData *d = [self http:@"POST" url:[kAPI stringByAppendingString:@"/pairing/get_lounge_token_batch"]
                      body:formBody(@[@[@"screen_ids", _screenID]]) status:&code];
    NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    NSDictionary *scr = [j isKindOfClass:[NSDictionary class]] ? [j[@"screens"] firstObject] : nil;
    NSString *tok = [scr isKindOfClass:[NSDictionary class]] ? scr[@"loungeToken"] : nil;
    if (code != 200 || ![tok isKindOfClass:[NSString class]]) { SFLog(@"lounge: token fetch failed (%ld)", (long)code); return NO; }
    _token = tok;
    double refreshMs = [scr[@"refreshIntervalInMillis"] doubleValue] ?: 1123200000.0;
    [[SFStore shared] setSetting:tok forKey:[self key:@"token"]];
    [[SFStore shared] setSetting:[NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970] + refreshMs / 1000.0] forKey:[self key:@"tokenRefresh"]];
    SFLog(@"lounge: new lounge token");
    return YES;
}

- (void)fetchPairingCode:(void (^)(NSString *, NSError *))done {
    dispatch_async(_q, ^{
        NSString *code = nil;
        for (int attempt = 0; attempt < 2 && !code; attempt++) {
            if (attempt == 1 || !self->_token || !self->_screenID) { if (![self ensureIdentity] || (attempt == 1 && ![self refreshToken])) break; }
            NSInteger st = 0;
            NSString *body = formBody(@[@[@"access_type", @"permanent"], @[@"app", @"sofa"], @[@"lounge_token", self->_token],
                                        @[@"screen_id", self->_screenID], @[@"screen_name", kScreenName], @[@"device_id", self->_deviceID]]);
            NSData *d = [self http:@"POST" url:[kAPI stringByAppendingString:@"/pairing/get_pairing_code?ctx=pair"] body:body status:&st];
            NSString *s = [[[NSString alloc] initWithData:d ?: [NSData data] encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (st == 200 && s.length == 12) code = s;
        }
        SFMain(^{ done(code, code ? nil : SFError(@"Kein Code verfügbar – YouTube nicht erreichbar.")); });
    });
}

#pragma mark Bind-Kanal

- (NSString *)commonParams {
    return formBody(@[@[@"device", @"LOUNGE_SCREEN"], @[@"id", _deviceID], @[@"name", kScreenName], @[@"app", @"sofa"],
                      @[@"theme", @"cl"], @[@"capabilities", @"dsp,mic,dpa,ntb"], @[@"mdxVersion", @"2"],
                      @[@"loungeIdToken", _token ?: @""], @[@"VER", @"8"], @[@"v", @"2"], @[@"t", @"1"]]);
}

- (NSString *)deviceInfo {
    return @"{\"brand\":\"Apple\",\"model\":\"iMac\",\"year\":0,\"os\":\"Mac OS X\",\"osVersion\":\"10.9.5\",\"chipset\":\"\",\"clientName\":\"TVHTML5\",\"dialAdditionalDataSupportLevel\":\"unsupported\",\"mdxDialServerType\":\"MDX_DIAL_SERVER_TYPE_UNKNOWN\"}";
}

// Neue Sitzung (auf _q). Rückgabe: HTTP-Status
- (NSInteger)openSession {
    _sid = nil; _gsid = nil; _aid = -1; _ofs = 0;
    _rid = 10000 + arc4random_uniform(80000);
    NSString *url = [NSString stringWithFormat:@"%@/bc/bind?%@&RID=%ld&CVER=1&%@&zx=%@", kAPI, [self commonParams], (long)_rid++,
                     formBody(@[@[@"deviceInfo", [self deviceInfo]]]), zx()];
    NSInteger st = 0;
    NSData *d = [self http:@"POST" url:url body:@"count=0" status:&st];
    if (st != 200 || !d) return st ?: -1;
    _frameBuf = [NSMutableData new];
    [self feed:d];
    if (!_sid) return -2;
    SFLog(@"lounge: session open");
    return 200;
}

- (BOOL)paused { return [[[SFStore shared] setting:[self key:@"paused"]] isEqualToString:@"1"]; }
- (void)setPaused:(BOOL)p {
    if (p == self.paused) return;
    [[SFStore shared] setSetting:p ? @"1" : @"0" forKey:[self key:@"paused"]];
    SFLog(@"lounge: Verbindung %@", p ? @"pausiert" : @"fortgesetzt");
    if (p) { [self stop]; [self dropSession]; }
    else [self start];
    [[NSNotificationCenter defaultCenter] postNotificationName:SFLoungeRemotesDidChangeNotification object:self];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SFLibraryDidChange" object:nil];   // Handy-Kachel (YouTube → Mehr) neu beschriften
}
- (BOOL)sharesAllPlayback { return [[[SFStore shared] setting:[self key:@"shareAll"]] isEqualToString:@"1"]; }
- (void)setSharesAllPlayback:(BOOL)s {
    [[SFStore shared] setSetting:s ? @"1" : @"0" forKey:[self key:@"shareAll"]];
    _lastVideo = nil;
    [self greet];   // Handy sofort auf den neuen Stand bringen (ggf. „nichts läuft“)
}

// Session lokal verwerfen (Kopplung/screenId bleibt)
- (void)dropSession {
    dispatch_sync(_q, ^{ self->_sid = nil; });
    @synchronized (_remotes) { [_remotes removeAllObjects]; }
}

- (void)forgetAllPhones {
    BOOL wasPaused = self.paused;
    [self stop];
    dispatch_sync(_q, ^{
        SFStore *st = [SFStore shared];
        for (NSString *k in @[@"screenId", @"token", @"tokenRefresh"]) [st setSetting:@"" forKey:[self key:k]];
        self->_screenID = nil; self->_token = nil; self->_sid = nil;
    });
    @synchronized (_remotes) { [_remotes removeAllObjects]; }
    SFLog(@"lounge: alle Handys getrennt (neue screenId)");
    [[NSNotificationCenter defaultCenter] postNotificationName:SFLoungeRemotesDidChangeNotification object:self];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SFLibraryDidChange" object:nil];   // Handy-Kachel (YouTube → Mehr) neu beschriften
    if (!wasPaused) [self start];
}

- (void)start {
    if (_running || self.paused) return;
    _running = YES;
    _loopGen++;
    [[NSNotificationCenter defaultCenter] removeObserver:self name:SFPlayerStateNotification object:nil];   // Fortsetzen: nicht doppelt
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerChanged:) name:SFPlayerStateNotification object:nil];
    // Laufende Position regelmäßig melden (Handy-Fortschrittsbalken)
    [_tick invalidate];
    _tick = [NSTimer scheduledTimerWithTimeInterval:10 target:self selector:@selector(periodic) userInfo:nil repeats:YES];
    [NSThread detachNewThreadSelector:@selector(runLoop) toTarget:self withObject:nil];
}

- (void)stop {
    if (!_running) return;
    _running = NO;
    _loopGen++;
    [_tick invalidate]; _tick = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self name:SFPlayerStateNotification object:nil];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(_q, ^{ if (self->_sid) [self sendNow:@[@[@"loungeScreenDisconnected", @{}]]]; dispatch_semaphore_signal(sem); });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)));   // best effort
}

- (void)runLoop {
    @autoreleasepool { [[NSThread currentThread] setName:@"sofa.lounge.poll"]; }
    double backoff = 1;
    NSUInteger gen = _loopGen;   // Pausieren/Fortsetzen startet eine neue Schleife; alte endet hier
    while (_running && gen == _loopGen) {
        @autoreleasepool {
            __block BOOL ok = NO;
            __block NSInteger st = 0;
            dispatch_sync(_q, ^{
                if (!self->_sid) {
                    if (![self ensureIdentity]) return;
                    st = [self openSession];
                    if (st == 401 || st == 410) { [self refreshToken]; st = [self openSession]; }
                    if (st == 200) dispatch_async(dispatch_get_main_queue(), ^{ [self greet]; });
                }
                ok = self->_sid != nil;
            });
            if (!ok) {
                SFLog(@"lounge: offline (%ld), retry in %.0fs", (long)st, backoff);
                [NSThread sleepForTimeInterval:backoff];
                backoff = MIN(backoff * 2, 120);
                continue;
            }
            NSInteger code = [self longPoll];
            if (gen != _loopGen) break;                              // inzwischen pausiert/neu gestartet: alte Schleife endet still
            if (code == 200) { backoff = 1; continue; }            // normales Ende nach ~5 min
            __block BOOL reset = NO;
            dispatch_sync(_q, ^{
                if (code == 400 || code == 404) reset = YES;                         // Unknown SID
                else if (code == 401 || code == 410) { [self refreshToken]; reset = YES; }
                else if (-[self->_lastAlive timeIntervalSinceNow] > 40) reset = YES;  // Idle-Limit ≈ 45–60 s
                if (reset) { self->_sid = nil; SFLog(@"lounge: session reset (%ld)", (long)code); }
            });
            if (!reset) { [NSThread sleepForTimeInterval:backoff]; backoff = MIN(backoff * 2, 8); }
        }
    }
}

- (NSInteger)longPoll {
    __block NSString *url = nil;
    dispatch_sync(_q, ^{
        url = [NSString stringWithFormat:@"%@/bc/bind?%@&RID=rpc&SID=%@&gsessionid=%@&CI=0&AID=%ld&TYPE=xmlhttp&zx=%@",
               kAPI, [self commonParams], self->_sid, formEncode(self->_gsid), (long)self->_aid, zx()];
        self->_frameBuf = [NSMutableData new];
    });
    CURL *c = SFCurlNew();
    if (!c) return -1;
    curl_easy_setopt(c, CURLOPT_URL, url.UTF8String);
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, lpWrite);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, (__bridge void *)self);
    curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT, 15L);
    curl_easy_setopt(c, CURLOPT_LOW_SPEED_LIMIT, 1L);     // noop alle ~28 s -> 70 s ohne Daten = tot
    curl_easy_setopt(c, CURLOPT_LOW_SPEED_TIME, 70L);
    curl_easy_setopt(c, CURLOPT_ACCEPT_ENCODING, "");
    CURLcode rc = curl_easy_perform(c);
    long code = 0;
    curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &code);
    curl_easy_cleanup(c);
    if (rc != CURLE_OK && code == 200) return -1;    // Abbruch mitten im Stream
    if (rc != CURLE_OK) SFLog(@"lounge: poll %s", curl_easy_strerror(rc));
    return code ?: -1;
}

static size_t lpWrite(char *ptr, size_t size, size_t n, void *ud) {
    SFLounge *s = (__bridge SFLounge *)ud;
    NSData *d = [NSData dataWithBytes:ptr length:size * n];
    dispatch_async(s->_q, ^{ [s feed:d]; });
    return size * n;
}

// Rahmen: "<len>\n<json>" (len inkl. abschließendem \n); auf _q
- (void)feed:(NSData *)d {
    _lastAlive = [NSDate date];
    [_frameBuf appendData:d];
    while (_frameBuf.length) {
        const char *b = _frameBuf.bytes;
        const char *nl = memchr(b, '\n', _frameBuf.length);
        if (!nl) return;
        NSUInteger hl = nl - b;
        NSInteger len = [[[NSString alloc] initWithBytes:b length:hl encoding:NSASCIIStringEncoding] integerValue];
        if (len <= 0) { [_frameBuf replaceBytesInRange:NSMakeRange(0, hl + 1) withBytes:NULL length:0]; continue; }
        if (_frameBuf.length < hl + 1 + len) return;
        NSData *js = [_frameBuf subdataWithRange:NSMakeRange(hl + 1, len)];
        [_frameBuf replaceBytesInRange:NSMakeRange(0, hl + 1 + len) withBytes:NULL length:0];
        NSArray *arr = [NSJSONSerialization JSONObjectWithData:js options:0 error:nil];
        if (![arr isKindOfClass:[NSArray class]]) continue;
        for (NSArray *entry in arr) {
            if (![entry isKindOfClass:[NSArray class]] || entry.count < 2) continue;
            NSInteger idx = [entry[0] integerValue];
            if (idx <= _aid) continue;     // schon gesehen
            _aid = idx;
            NSArray *msg = entry[1];
            if (![msg isKindOfClass:[NSArray class]] || !msg.count) continue;
            NSString *name = msg[0];
            if ([name isEqualToString:@"c"]) { _sid = msg.count > 1 ? msg[1] : nil; continue; }
            if ([name isEqualToString:@"S"]) { _gsid = msg.count > 1 ? msg[1] : nil; continue; }
            if ([name isEqualToString:@"noop"]) continue;
            NSDictionary *args = msg.count > 1 && [msg[1] isKindOfClass:[NSDictionary class]] ? msg[1] : @{};
            dispatch_async(dispatch_get_main_queue(), ^{ [self handle:name args:args]; });
        }
    }
}

#pragma mark Senden

// auf _q: eine POST mit allen Nachrichten, ofs exakt fortlaufend
- (void)sendNow:(NSArray *)msgs {
    if (!_sid || !msgs.count) return;
    NSMutableArray *pairs = [NSMutableArray arrayWithObjects:@[@"count", [@(msgs.count) stringValue]], @[@"ofs", [@(_ofs) stringValue]], nil];
    for (NSUInteger i = 0; i < msgs.count; i++) {
        NSArray *m = msgs[i];
        [pairs addObject:@[[NSString stringWithFormat:@"req%lu__sc", (unsigned long)i], m[0]]];
        [(NSDictionary *)m[1] enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
            [pairs addObject:@[[NSString stringWithFormat:@"req%lu_%@", (unsigned long)i, k], [v description]]];
        }];
    }
    NSString *url = [NSString stringWithFormat:@"%@/bc/bind?%@&SID=%@&gsessionid=%@&RID=%ld&AID=%ld&zx=%@",
                     kAPI, [self commonParams], _sid, formEncode(_gsid), (long)_rid++, (long)_aid, zx()];
    NSInteger st = 0;
    [self http:@"POST" url:url body:formBody(pairs) status:&st];
    if (st == 200) _ofs += msgs.count;
    else SFLog(@"lounge: send %@ -> %ld", msgs.firstObject[0], (long)st);
}

- (void)send:(NSArray *)msgs { dispatch_async(_q, ^{ [self sendNow:msgs]; }); }

#pragma mark Zustand -> Handy

- (SFPlayerScreen *)player {
    id p = self.playerProvider ? self.playerProvider() : nil;
    return [p isKindOfClass:[SFPlayerScreen class]] ? p : nil;
}

- (NSString *)videoIDOf:(SFPlayerScreen *)p {
    // Privatsphäre: am Sofa gestartete Wiedergabe nur teilen, wenn ausdrücklich erlaubt
    if (!p.remoteListID && !self.sharesAllPlayback) return nil;
    NSString *v = p.item.externalID;
    return [p.item.source isEqualToString:@"youtube"] && v.length == 11 ? v : nil;
}

- (NSDictionary *)stateArgs:(SFPlayerScreen *)p {
    NSString *vid = [self videoIDOf:p];
    if (!p || !vid) return @{@"state": @"-1", @"currentTime": @"0", @"duration": @"0", @"loadedTime": @"0",
                             @"seekableStartTime": @"0", @"seekableEndTime": @"0", @"cpn": _cpn};
    double d = [p duration];
    return @{@"state": [@(p.playbackState) stringValue], @"currentTime": fmtTime([p currentTime]), @"duration": fmtTime(d),
             @"loadedTime": fmtTime(d), @"seekableStartTime": @"0", @"seekableEndTime": fmtTime(d), @"cpn": _cpn};
}

- (NSDictionary *)nowPlayingArgs:(SFPlayerScreen *)p {
    NSString *vid = [self videoIDOf:p];
    if (!vid) return @{};
    NSMutableDictionary *a = [[self stateArgs:p] mutableCopy];
    a[@"videoId"] = vid;
    a[@"currentIndex"] = [@(p.remoteListID ? p.queueIndex : 0) stringValue];
    if (p.remoteListID) a[@"listId"] = p.remoteListID;
    return a;
}

- (NSArray *)volumeMessage {
    int vol = (int)lroundf(MAX(0, [SFVolume volume]) * 100);
    return @[@"onVolumeChanged", @{@"volume": [@(vol) stringValue], @"muted": [SFVolume muted] ? @"true" : @"false"}];
}

- (NSArray *)fullStateMessages {
    SFPlayerScreen *p = [self player];
    return @[@[@"onHasPreviousNextChanged", @{@"hasPrevious": p.hasPrevious ? @"true" : @"false", @"hasNext": p.hasNext ? @"true" : @"false"}],
             @[@"nowPlaying", [self nowPlayingArgs:p]],
             @[@"onStateChange", [self stateArgs:p]],
             [self volumeMessage],
             @[@"onAutoplayModeChanged", @{@"autoplayMode": @"UNSUPPORTED"}]];
}

- (void)greet { [self send:[self fullStateMessages]]; }

- (void)playerChanged:(NSNotification *)n {
    SFPlayerScreen *p = n.object;
    BOOL closed = [n.userInfo[@"closed"] boolValue];
    if (closed) {
        if (_lastVideo) { _lastVideo = nil; _lastState = SFPlaybackIdle; [self send:@[@[@"nowPlaying", @{}], @[@"onStateChange", [self stateArgs:nil]]]]; }
        return;
    }
    NSString *vid = [self videoIDOf:p];
    SFPlaybackState s = p.playbackState;
    if (!vid && !_lastVideo) return;   // Nicht-YouTube-Wiedergabe: nichts zu melden
    if (!(vid == _lastVideo || [vid isEqualToString:_lastVideo])) {
        _lastVideo = vid; _lastState = s; _cpn = [self newCPN];
        [self send:@[@[@"nowPlaying", [self nowPlayingArgs:p]], @[@"onStateChange", [self stateArgs:p]],
                     @[@"onHasPreviousNextChanged", @{@"hasPrevious": p.hasPrevious ? @"true" : @"false", @"hasNext": p.hasNext ? @"true" : @"false"}]]];
        return;
    }
    if (s != _lastState) {
        _lastState = s;
        if (vid) [self send:@[@[@"onStateChange", [self stateArgs:p]]]];
    }
}

- (void)periodic {
    SFPlayerScreen *p = [self player];
    @synchronized (_remotes) { if (!_remotes.count) return; }
    if (p && [self videoIDOf:p] && p.playbackState == SFPlaybackPlaying) [self send:@[@[@"onStateChange", [self stateArgs:p]]]];
}

#pragma mark Befehle vom Handy (Main-Thread)

- (void)updateRemotesFromStatus:(NSDictionary *)args {
    NSArray *devs = [NSJSONSerialization JSONObjectWithData:[args[@"devices"] ?: @"[]" dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![devs isKindOfClass:[NSArray class]]) return;
    NSMutableDictionary *now = [NSMutableDictionary new];
    for (NSDictionary *d in devs) {
        if (![d isKindOfClass:[NSDictionary class]] || ![d[@"type"] isEqualToString:@"REMOTE_CONTROL"]) continue;
        now[d[@"id"] ?: @"?"] = d[@"name"] ?: @"Handy";
    }
    BOOL newOne = NO;
    @synchronized (_remotes) {
        for (NSString *k in now) if (!_remotes[k]) newOne = YES;
        [_remotes setDictionary:now];
    }
    if (newOne) [self greet];
    [[NSNotificationCenter defaultCenter] postNotificationName:SFLoungeRemotesDidChangeNotification object:self];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SFLibraryDidChange" object:nil];   // Handy-Kachel (YouTube → Mehr) neu beschriften
}

- (void)handle:(NSString *)cmd args:(NSDictionary *)args {
    if (self.paused) return;   // pausiert: nichts mehr annehmen (auch nicht über eine noch offene alte Verbindung)
    if (![cmd isEqualToString:@"getNowPlaying"]) SFLog(@"lounge: <- %@", cmd);
    SFPlayerScreen *p = [self player];
    if ([cmd isEqualToString:@"loungeStatus"]) { [self updateRemotesFromStatus:args]; return; }
    if ([cmd isEqualToString:@"remoteConnected"]) {
        @synchronized (_remotes) { _remotes[args[@"id"] ?: @"?"] = args[@"name"] ?: @"Handy"; }
        [self greet];
        [[NSNotificationCenter defaultCenter] postNotificationName:SFLoungeRemotesDidChangeNotification object:self];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SFLibraryDidChange" object:nil];   // Handy-Kachel (YouTube → Mehr) neu beschriften
    } else if ([cmd isEqualToString:@"remoteDisconnected"]) {
        @synchronized (_remotes) { [_remotes removeObjectForKey:args[@"id"] ?: @"?"]; }
        [[NSNotificationCenter defaultCenter] postNotificationName:SFLoungeRemotesDidChangeNotification object:self];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SFLibraryDidChange" object:nil];   // Handy-Kachel (YouTube → Mehr) neu beschriften
    } else if ([cmd isEqualToString:@"getNowPlaying"]) {
        [self send:@[@[@"nowPlaying", [self nowPlayingArgs:p]]]];
        return;
    } else if ([cmd isEqualToString:@"getVolume"]) {
        [self send:@[[self volumeMessage]]];
        return;
    } else if ([cmd isEqualToString:@"setVolume"]) {
        if (!SFDevMode) {
            if (args[@"volume"]) [SFVolume setVolume:[args[@"volume"] floatValue] / 100.0f];
            else if (args[@"delta"]) [SFVolume setVolume:MAX(0, MIN(1, [SFVolume volume] + [args[@"delta"] floatValue] / 100.0f))];
            if (args[@"muted"]) [SFVolume setMuted:[args[@"muted"] isEqualToString:@"true"]];
        }
        [self send:@[[self volumeMessage]]];
        return;
    } else if ([cmd isEqualToString:@"getSubtitlesTrack"]) {
        [self send:@[@[@"onSubtitlesTrackChanged", @{@"videoId": [self videoIDOf:p] ?: @""}]]];
        return;
    } else if ([cmd isEqualToString:@"setAutoplayMode"]) {
        [self send:@[@[@"onAutoplayModeChanged", @{@"autoplayMode": @"UNSUPPORTED"}]]];
        return;
    } else if ([cmd isEqualToString:@"setPlaylist"] || [cmd isEqualToString:@"setVideo"]) {
        // sofort "lädt" melden, das Handy zeigt sonst lange nichts
        NSString *vid = args[@"videoId"];
        if (vid) [self send:@[@[@"nowPlaying", @{@"videoId": vid, @"state": @"3", @"currentTime": args[@"currentTime"] ?: @"0", @"duration": @"0",
                                                 @"currentIndex": args[@"currentIndex"] ?: @"0", @"listId": args[@"listId"] ?: @"", @"cpn": _cpn,
                                                 @"loadedTime": @"0", @"seekableStartTime": @"0", @"seekableEndTime": @"0"}],
                              @[@"onStateChange", @{@"state": @"3", @"currentTime": args[@"currentTime"] ?: @"0", @"duration": @"0", @"cpn": _cpn,
                                                    @"loadedTime": @"0", @"seekableStartTime": @"0", @"seekableEndTime": @"0"}]]];
    }
    if (self.commandHandler) self.commandHandler(cmd, args);
}
@end
