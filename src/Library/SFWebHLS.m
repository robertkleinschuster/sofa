#import "SFWebHLS.h"

static const long long kMaxHeaderBox = 8 << 20;   // a moov or sidx beyond this is no header we read
static const int kMaxTopBoxes = 32;

static uint32_t BE32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint16_t BE16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static uint64_t BE64(const uint8_t *p) { return (uint64_t)BE32(p) << 32 | BE32(p + 4); }

// The first child box of `type` in [start, end) of d: its content range (after the header); NO when absent.
static BOOL FindBox(NSData *d, NSUInteger start, NSUInteger end, const char *type, NSUInteger *cs, NSUInteger *ce) {
    const uint8_t *b = d.bytes;
    NSUInteger at = start;
    while (at + 8 <= end) {
        uint64_t size = BE32(b + at);
        NSUInteger hdr = 8;
        if (size == 1) { if (at + 16 > end) return NO; size = BE64(b + at + 8); hdr = 16; }
        else if (size == 0) size = end - at;
        if (size < hdr || at + size > end) return NO;
        if (memcmp(b + at + 4, type, 4) == 0) { *cs = at + hdr; *ce = (NSUInteger)(at + size); return YES; }
        at += (NSUInteger)size;
    }
    return NO;
}

static BOOL FindPath(NSData *d, NSUInteger start, NSUInteger end, NSArray *path, NSUInteger *cs, NSUInteger *ce) {
    NSUInteger s = start, e = end;
    for (NSString *t in path) if (!FindBox(d, s, e, t.UTF8String, &s, &e)) return NO;
    *cs = s; *ce = e;
    return YES;
}

// An MPEG-4 descriptor at *at: its tag and the range of its payload; *at moves past it.
static BOOL ReadDescriptor(const uint8_t *b, NSUInteger end, NSUInteger *at, uint8_t *tag, NSUInteger *ps, NSUInteger *pe) {
    if (*at >= end) return NO;
    *tag = b[(*at)++];
    NSUInteger len = 0;
    for (int i = 0; i < 4; i++) {
        if (*at >= end) return NO;
        uint8_t c = b[(*at)++];
        len = len << 7 | (c & 0x7F);
        if (!(c & 0x80)) break;
    }
    if (*at + len > end) return NO;
    *ps = *at; *pe = *at + len; *at = *pe;
    return YES;
}

// esds -> "mp4a.<objectTypeIndication hex>.<audioObjectType>"
static NSString *AACCodec(NSData *d, NSUInteger s, NSUInteger e) {
    const uint8_t *b = d.bytes;
    NSUInteger at = s + 4, ps, pe;   // after version + flags
    uint8_t tag;
    if (!ReadDescriptor(b, e, &at, &tag, &ps, &pe) || tag != 0x03 || pe - ps < 3) return nil;   // ES_Descriptor
    NSUInteger p = ps + 2;
    uint8_t flags = b[p++];
    if (flags & 0x80) p += 2;
    if (flags & 0x40) { if (p >= pe) return nil; p += 1 + b[p]; }
    if (flags & 0x20) p += 2;
    if (!ReadDescriptor(b, pe, &p, &tag, &ps, &pe) || tag != 0x04 || pe - ps < 13) return nil;   // DecoderConfigDescriptor
    uint8_t oti = b[ps];
    NSUInteger q = ps + 13;
    NSUInteger ss, se;
    if (!ReadDescriptor(b, pe, &q, &tag, &ss, &se) || tag != 0x05 || se <= ss) return nil;   // DecoderSpecificInfo
    unsigned aot = b[ss] >> 3;
    if (aot == 31) { if (se - ss < 2) return nil; aot = 32 + (((b[ss] & 0x07) << 3) | (b[ss + 1] >> 5)); }
    return [NSString stringWithFormat:@"mp4a.%x.%u", oti, aot];
}

@interface SFFMP4Track ()
@property (nonatomic) long long initEnd;
@property (nonatomic, copy) NSArray *segments;
@property (nonatomic, copy) NSString *codec;
@property (nonatomic) int width, height;
@property (nonatomic) double duration;
@property (nonatomic) BOOL isVideo;
@end

@implementation SFFMP4Track

// moov -> codec (and the picture size): the first track's first sample entry
- (BOOL)readMoov:(NSData *)m why:(NSString **)why {
    NSUInteger s, e;
    if (!FindPath(m, 8, m.length, @[@"trak", @"mdia", @"minf", @"stbl", @"stsd"], &s, &e) || e - s < 16) { *why = @"no sample description"; return NO; }
    const uint8_t *b = m.bytes;
    NSUInteger entry = s + 8, size = BE32(b + entry);   // after version/flags + entry count
    if (size < 8 || entry + size > e) { *why = @"broken sample entry"; return NO; }
    NSString *type = [[NSString alloc] initWithBytes:b + entry + 4 length:4 encoding:NSASCIIStringEncoding];
    NSUInteger content = entry + 8, end = entry + size, cs, ce;
    if ([type isEqualToString:@"avc1"] || [type isEqualToString:@"avc3"]) {
        if (content + 78 > end) { *why = @"short video sample entry"; return NO; }
        _width = BE16(b + content + 24); _height = BE16(b + content + 26);
        if (!FindBox(m, content + 78, end, "avcC", &cs, &ce) || ce - cs < 4) { *why = @"no avcC"; return NO; }
        _codec = [NSString stringWithFormat:@"%@.%02x%02x%02x", type, b[cs + 1], b[cs + 2], b[cs + 3]];
        _isVideo = YES;
        return YES;
    }
    if ([type isEqualToString:@"av01"]) {
        // av1C (AV1 ISOBMFF binding 2.3): marker/version, seq_profile(3) seq_level_idx_0(5),
        // seq_tier_0(1) high_bitdepth(1) twelve_bit(1) ... -> "av01.<profile>.<level><tier>.<bit depth>"
        if (content + 78 > end) { *why = @"short video sample entry"; return NO; }
        _width = BE16(b + content + 24); _height = BE16(b + content + 26);
        if (!FindBox(m, content + 78, end, "av1C", &cs, &ce) || ce - cs < 4 || b[cs] != 0x81) { *why = @"no av1C"; return NO; }
        int depth = (b[cs + 2] & 0x40) ? ((b[cs + 2] & 0x20) ? 12 : 10) : 8;
        _codec = [NSString stringWithFormat:@"av01.%d.%02d%c.%02d", b[cs + 1] >> 5, b[cs + 1] & 0x1f, (b[cs + 2] & 0x80) ? 'H' : 'M', depth];
        _isVideo = YES;
        return YES;
    }
    if ([type isEqualToString:@"mp4a"]) {
        if (content + 28 > end || !FindBox(m, content + 28, end, "esds", &cs, &ce)) { *why = @"no esds"; return NO; }
        _codec = AACCodec(m, cs, ce);
        if (!_codec) { *why = @"unreadable esds"; return NO; }
        return YES;
    }
    *why = [NSString stringWithFormat:@"sample entry %@ is not H.264, AV1 or AAC", type];
    return NO;
}

// sidx (whole box at file offset `at`) -> segments
- (BOOL)readSidx:(NSData *)x at:(long long)at why:(NSString **)why {
    const uint8_t *b = x.bytes;
    NSUInteger n = x.length, p = 8;
    if (n < p + 12) { *why = @"short sidx"; return NO; }
    uint8_t version = b[p];
    uint32_t timescale = BE32(b + p + 8);
    p += 12;
    uint64_t first;
    if (version == 0) { if (n < p + 8) { *why = @"short sidx"; return NO; } first = BE32(b + p + 4); p += 8; }
    else { if (n < p + 16) { *why = @"short sidx"; return NO; } first = BE64(b + p + 8); p += 16; }
    uint16_t count = BE16(b + p + 2);
    p += 4;
    if (!timescale || !count || n < p + 12 * (NSUInteger)count) { *why = @"empty sidx"; return NO; }
    long long off = at + (long long)n + (long long)first;   // first_offset counts from the end of the sidx
    NSMutableArray *segs = [NSMutableArray arrayWithCapacity:count];
    double total = 0;
    for (uint16_t i = 0; i < count; i++, p += 12) {
        uint32_t ref = BE32(b + p);
        if (ref & 0x80000000u) { *why = @"hierarchical sidx"; return NO; }
        long long len = ref & 0x7FFFFFFFu;
        double secs = (double)BE32(b + p + 4) / timescale;
        [segs addObject:@[@(off), @(len), @(secs)]];
        off += len; total += secs;
    }
    _segments = segs;
    _duration = total;
    return YES;
}

+ (instancetype)trackWithReader:(NSData *(^)(long long, NSUInteger))read error:(NSString **)whyOut {
    SFFMP4Track *t = [SFFMP4Track new];
    NSString *why = nil;
    long long off = 0;
    BOOL moov = NO;
    for (int i = 0; i < kMaxTopBoxes && !why; i++) {
        NSData *h = read(off, 16);
        if (h.length < 8) { why = @"unreadable header"; break; }
        const uint8_t *b = h.bytes;
        long long size = BE32(b);
        if (size == 1) { if (h.length < 16) { why = @"unreadable header"; break; } size = (long long)BE64(b + 8); }
        if (size < 8) { why = @"box without a size"; break; }
        char type[5] = {0};
        memcpy(type, b + 4, 4);
        if (!strcmp(type, "moov") || !strcmp(type, "sidx")) {
            if (size > kMaxHeaderBox) { why = [NSString stringWithFormat:@"%s of %lld bytes", type, size]; break; }
            NSData *box = read(off, (NSUInteger)size);
            if ((long long)box.length != size) { why = [NSString stringWithFormat:@"%s unreadable", type]; break; }
            if (type[0] == 'm') { if (![t readMoov:box why:&why]) break; moov = YES; t.initEnd = off + size; }
            else {
                if (!moov) { why = @"sidx before moov"; break; }
                if ([t readSidx:box at:off why:&why]) { if (whyOut) *whyOut = nil; return t; }
                break;
            }
        } else if (!strcmp(type, "moof") || !strcmp(type, "mdat")) { why = @"no sidx before the media"; break; }
        off += size;
    }
    if (whyOut) *whyOut = why ?: @"no sidx";
    return nil;
}
@end

static void Peak(SFFMP4Track *t, double *peak, double *avg) {
    double bytes = 0, best = 0;
    for (NSArray *s in t.segments) {
        double len = [s[1] doubleValue], secs = [s[2] doubleValue];
        bytes += len;
        if (secs > 0) best = MAX(best, len * 8 / secs);
    }
    *peak = best;
    *avg = t.duration > 0 ? bytes * 8 / t.duration : 0;
}

NSString *SFHLSMasterPlaylist(SFFMP4Track *v, SFFMP4Track *a, NSString *videoPlaylist, NSString *audioPlaylist) {
    double vp, va, ap, aa;
    Peak(v, &vp, &va); Peak(a, &ap, &aa);
    NSMutableString *m = [NSMutableString stringWithString:@"#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"];
    [m appendFormat:@"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"Ton\",DEFAULT=YES,AUTOSELECT=YES,URI=\"%@\"\n", audioPlaylist];
    [m appendFormat:@"#EXT-X-STREAM-INF:BANDWIDTH=%.0f,AVERAGE-BANDWIDTH=%.0f,CODECS=\"%@,%@\"", ceil(vp + ap), ceil(va + aa), v.codec, a.codec];
    if (v.width && v.height) [m appendFormat:@",RESOLUTION=%dx%d", v.width, v.height];
    [m appendFormat:@",AUDIO=\"a\"\n%@\n", videoPlaylist];
    return m;
}

NSString *SFHLSMediaPlaylist(SFFMP4Track *t, NSString *uri) {
    double target = 1;
    for (NSArray *s in t.segments) target = MAX(target, ceil([s[2] doubleValue]));
    NSMutableString *m = [NSMutableString stringWithFormat:@"#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:%.0f\n#EXT-X-PLAYLIST-TYPE:VOD\n"
                          "#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-MAP:URI=\"%@\",BYTERANGE=\"%lld@0\"\n", target, uri, t.initEnd];
    for (NSArray *s in t.segments)
        [m appendFormat:@"#EXTINF:%.6f,\n#EXT-X-BYTERANGE:%lld@%lld\n%@\n", [s[2] doubleValue], [s[1] longLongValue], [s[0] longLongValue], uri];
    [m appendString:@"#EXT-X-ENDLIST\n"];
    return m;
}
