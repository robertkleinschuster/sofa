#import "SFMP4Index.h"
#import "SFCore.h"

#define FCC(a, b, c, d) ((uint32_t)(a) << 24 | (uint32_t)(b) << 16 | (uint32_t)(c) << 8 | (uint32_t)(d))
static const long long kMaxMoov = 64LL << 20;   // a moov larger than this is no file of ours

static uint32_t U32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint64_t U64(const uint8_t *p) { return (uint64_t)U32(p) << 32 | U32(p + 4); }

// the boxes in [from, to): b(type, payload start, payload end); stops at a malformed one
static void Boxes(const uint8_t *d, size_t from, size_t to, void (^b)(uint32_t type, size_t p, size_t e)) {
    size_t o = from;
    while (o + 8 <= to) {
        uint64_t size = U32(d + o);
        uint32_t type = U32(d + o + 4);
        size_t hdr = 8;
        if (size == 1) { if (o + 16 > to) return; size = U64(d + o + 8); hdr = 16; }
        else if (size == 0) size = to - o;
        if (size < hdr || size > to - o) return;
        b(type, o + hdr, o + (size_t)size);
        o += (size_t)size;
    }
}

// the first child of type t: its payload range (NO when absent)
static BOOL Child(const uint8_t *d, size_t from, size_t to, uint32_t t, size_t *p, size_t *e) {
    __block BOOL found = NO;
    Boxes(d, from, to, ^(uint32_t type, size_t bp, size_t be) { if (!found && type == t) { found = YES; *p = bp; *e = be; } });
    return found;
}

@implementation SFMP4Index

+ (instancetype)indexWithLength:(long long)total read:(NSData *(^)(long long, NSUInteger))read {
    long long o = 0;
    while (o + 8 <= total) {   // the top-level boxes up to moov
        NSData *h = read(o, (NSUInteger)MIN(16, total - o));
        if (h.length < 8) return nil;
        const uint8_t *b = h.bytes;
        uint64_t size = U32(b);
        if (size == 1) { if (h.length < 16) return nil; size = U64(b + 8); }
        else if (size == 0) size = (uint64_t)(total - o);
        if (size < 8 || (long long)size > total - o) return nil;
        if (U32(b + 4) == FCC('m', 'o', 'o', 'v')) {
            if ((long long)size > kMaxMoov) return nil;
            NSData *moov = read(o, (NSUInteger)size);
            return moov.length == size ? [[self alloc] initWithMoov:moov] : nil;
        }
        o += (long long)size;
    }
    return nil;
}

- (instancetype)initWithMoov:(NSData *)moov {
    if (!(self = [super init])) return nil;
    const uint8_t *d = moov.bytes;
    size_t len = moov.length, hdr = U32(d) == 1 ? 16 : 8;
    __block uint32_t movieScale = 0;
    size_t mp, me;
    if (Child(d, hdr, len, FCC('m', 'v', 'h', 'd'), &mp, &me) && me - mp >= 32)
        movieScale = d[mp] == 1 ? U32(d + mp + 20) : U32(d + mp + 12);
    NSMutableArray *tracks = [NSMutableArray new];
    Boxes(d, hdr, len, ^(uint32_t type, size_t p, size_t e) {
        if (type != FCC('t', 'r', 'a', 'k')) return;
        NSArray *chunks = [self chunksOfTrak:d from:p to:e movieScale:movieScale];
        if (chunks.count) [tracks addObject:chunks];
    });
    _tracks = tracks;
    return tracks.count ? self : nil;
}

// an audio/video track's chunks: @[byte start, byte end, t0, t1]; nil for any other track or bad tables
- (NSArray *)chunksOfTrak:(const uint8_t *)d from:(size_t)from to:(size_t)to movieScale:(uint32_t)movieScale {
    size_t mdia, mdiaE, p, e, stbl, stblE;
    if (!Child(d, from, to, FCC('m', 'd', 'i', 'a'), &mdia, &mdiaE)) return nil;
    if (!Child(d, mdia, mdiaE, FCC('h', 'd', 'l', 'r'), &p, &e) || e - p < 12) return nil;
    uint32_t handler = U32(d + p + 8);
    if (handler != FCC('v', 'i', 'd', 'e') && handler != FCC('s', 'o', 'u', 'n')) return nil;
    if (!Child(d, mdia, mdiaE, FCC('m', 'd', 'h', 'd'), &p, &e) || e - p < 24) return nil;
    uint32_t scale = d[p] == 1 ? U32(d + p + 20) : U32(d + p + 12);
    if (!scale) return nil;
    // an edit list: an empty edit first delays the track (movie time), the first real edit's media time is its start
    double delay = 0; int64_t mediaStart = 0;
    size_t ed, edE;
    if (Child(d, from, to, FCC('e', 'd', 't', 's'), &ed, &edE) && Child(d, ed, edE, FCC('e', 'l', 's', 't'), &p, &e) && e - p >= 8) {
        BOOL v1 = d[p] == 1;
        uint32_t n = U32(d + p + 4);
        size_t step = v1 ? 20 : 12, q = p + 8;
        for (uint32_t i = 0; i < n && q + step <= e; i++, q += step) {
            uint64_t segDur = v1 ? U64(d + q) : U32(d + q);
            int64_t mt = v1 ? (int64_t)U64(d + q + 8) : (int32_t)U32(d + q + 4);
            if (mt < 0) { if (movieScale) delay += (double)segDur / movieScale; continue; }
            mediaStart = mt; break;
        }
    }
    size_t minf, minfE;
    if (!Child(d, mdia, mdiaE, FCC('m', 'i', 'n', 'f'), &minf, &minfE) || !Child(d, minf, minfE, FCC('s', 't', 'b', 'l'), &stbl, &stblE)) return nil;
    size_t tts, ttsE, sc, scE, sz, szE, co, coE;
    if (!Child(d, stbl, stblE, FCC('s', 't', 't', 's'), &tts, &ttsE) || !Child(d, stbl, stblE, FCC('s', 't', 's', 'c'), &sc, &scE)
        || !Child(d, stbl, stblE, FCC('s', 't', 's', 'z'), &sz, &szE)) return nil;
    BOOL co64 = NO;
    if (!Child(d, stbl, stblE, FCC('s', 't', 'c', 'o'), &co, &coE)) {
        if (!Child(d, stbl, stblE, FCC('c', 'o', '6', '4'), &co, &coE)) return nil;
        co64 = YES;
    }
    uint32_t chunks = U32(d + co + 4), scN = U32(d + sc + 4), ttsN = U32(d + tts + 4);
    uint32_t fixedSize = U32(d + sz + 4), samples = U32(d + sz + 8);
    if (co + 8 + (size_t)chunks * (co64 ? 8 : 4) > coE || sc + 8 + (size_t)scN * 12 > scE || tts + 8 + (size_t)ttsN * 8 > ttsE
        || (!fixedSize && sz + 12 + (size_t)samples * 4 > szE) || !scN) return nil;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:chunks];
    uint32_t s = 0, scI = 0, ttsI = 0, ttsLeft = ttsN ? U32(d + tts + 8) : 0;
    uint64_t dts = 0;
    for (uint32_t c = 1; c <= chunks && s < samples; c++) {
        while (scI + 1 < scN && U32(d + sc + 8 + (size_t)(scI + 1) * 12) <= c) scI++;
        uint32_t per = U32(d + sc + 8 + (size_t)scI * 12 + 4);
        long long off = co64 ? (long long)U64(d + co + 8 + (size_t)(c - 1) * 8) : U32(d + co + 8 + (size_t)(c - 1) * 4);
        long long bytes = 0;
        uint64_t t0 = dts;
        for (uint32_t k = 0; k < per && s < samples; k++, s++) {
            bytes += fixedSize ? fixedSize : U32(d + sz + 12 + (size_t)s * 4);
            while (!ttsLeft && ttsI + 1 < ttsN) { ttsI++; ttsLeft = U32(d + tts + 8 + (size_t)ttsI * 8); }
            dts += U32(d + tts + 8 + (size_t)ttsI * 8 + 4);
            if (ttsLeft) ttsLeft--;
        }
        double a = delay + ((double)t0 - mediaStart) / scale, b = delay + ((double)dts - mediaStart) / scale;
        if (bytes > 0 && b > a) [out addObject:@[@(off), @(off + bytes), @(MAX(0, a)), @(b)]];
    }
    return out;
}

- (NSArray *)storedRanges:(BOOL (^)(long long, long long))covered {
    NSArray *all = nil;
    for (NSArray *chunks in _tracks) {
        NSMutableArray *r = [NSMutableArray new];
        for (NSArray *c in chunks)
            if (covered([c[0] longLongValue], [c[1] longLongValue])) SFRangesAppend(r, [c[2] doubleValue], [c[3] doubleValue]);
        all = all ? SFRangesIntersect(all, r) : r;
    }
    return all ?: @[];
}

@end
