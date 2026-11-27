// sources: src/Library/SFWebHLS.m
// flags: -Isrc/Library
// SFWebHLS (Sofa im Browser, docs/pwa.md): a pair of fragmented MP4 tracks laid out like YouTube's
// DASH files (ftyp, moov, sidx, moof/mdat...; tests/fixtures/web, made by ffmpeg) becomes HLS: the
// codecs from avcC/av1C/esds, the init range, the sidx's subsegments as byte ranges - read through header
// ranges only, never past the sidx. Broken or foreign tracks are refused.
#import "SFWebHLS.h"

BOOL SFDevMode = NO;

static int fails = 0;
#define CHECK(c, msg) do { if (!(c)) { fprintf(stderr, "FAIL %s (%s:%d)\n", msg, __FILE__, __LINE__); fails++; } } while (0)

static NSData *Fixture(NSString *name) {
    NSString *dir = [[@(__FILE__) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"../fixtures/web"];
    return [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:name]];
}

static SFFMP4Track *Parse(NSData *file, long long *maxRead, NSString **why) {
    *maxRead = 0;
    return [SFFMP4Track trackWithReader:^NSData *(long long off, NSUInteger len) {
        if (off >= (long long)file.length) return [NSData data];
        NSUInteger n = (NSUInteger)MIN((long long)len, (long long)file.length - off);
        *maxRead = MAX(*maxRead, off + (long long)n);
        return [file subdataWithRange:NSMakeRange((NSUInteger)off, n)];
    } error:why];
}

int main(void) {
    @autoreleasepool {
        NSData *v = Fixture(@"video.mp4"), *a = Fixture(@"audio.mp4");
        CHECK(v.length && a.length, "fixtures present");
        long long maxRead = 0;
        NSString *why = nil;
        SFFMP4Track *vt = Parse(v, &maxRead, &why);
        CHECK(vt != nil, [[@"video parsed: " stringByAppendingString:why ?: @""] UTF8String]);
        CHECK(vt.isVideo, "video is video");
        CHECK([vt.codec isEqualToString:@"avc1.64000a"], [[@"H.264 High level 1.0 codec string, got " stringByAppendingString:vt.codec ?: @"nil"] UTF8String]);
        CHECK(vt.width == 96 && vt.height == 54, "picture size from the sample entry");
        CHECK(vt.initEnd == 28 + 714, "init = ftyp + moov");
        CHECK(maxRead <= 742 + 88, "only header ranges read (up to the end of the sidx)");
        CHECK(vt.segments.count == 4, "one segment per sidx reference (4 s, a keyframe each second)");
        long long expect = 742 + 88, total = 0;
        BOOL contiguous = YES;
        for (NSArray *s in vt.segments) { if ([s[0] longLongValue] != expect) contiguous = NO; expect += [s[1] longLongValue]; total += [s[1] longLongValue]; }
        CHECK(contiguous, "segments follow the sidx without gaps");
        CHECK(expect == (long long)v.length - 124, "the segments end where the media ends (before ffmpeg's trailing mfra)");
        CHECK(fabs(vt.duration - 4) < 0.05, "duration from the sidx");

        SFFMP4Track *at = Parse(a, &maxRead, &why);
        CHECK(at && !at.isVideo, [[@"audio parsed: " stringByAppendingString:why ?: @""] UTF8String]);
        CHECK([at.codec isEqualToString:@"mp4a.40.2"], [[@"AAC-LC codec string, got " stringByAppendingString:at.codec ?: @"nil"] UTF8String]);
        CHECK(at.initEnd == 28 + 664, "audio init");
        long long aEnd = 0;
        for (NSArray *s in at.segments) aEnd = [s[0] longLongValue] + [s[1] longLongValue];
        CHECK(aEnd == (long long)a.length - 124, "audio segments end where its media ends");

        NSString *master = SFHLSMasterPlaylist(vt, at, @"v.m3u8", @"a.m3u8");
        CHECK([master rangeOfString:@"CODECS=\"avc1.64000a,mp4a.40.2\""].location != NSNotFound, "master names both codecs");
        CHECK([master rangeOfString:@"RESOLUTION=96x54"].location != NSNotFound, "master names the resolution");
        CHECK([master rangeOfString:@"TYPE=AUDIO,GROUP-ID=\"a\""].location != NSNotFound && [master rangeOfString:@"URI=\"a.m3u8\""].location != NSNotFound, "audio rendition");
        CHECK([master rangeOfString:@"BANDWIDTH="].location != NSNotFound, "bandwidth");
        NSString *media = SFHLSMediaPlaylist(vt, @"t/v");
        CHECK([media rangeOfString:@"#EXT-X-MAP:URI=\"t/v\",BYTERANGE=\"742@0\""].location != NSNotFound, "init as EXT-X-MAP byte range");
        NSString *firstRange = [NSString stringWithFormat:@"#EXT-X-BYTERANGE:%@@830\nt/v", vt.segments[0][1]];
        CHECK([media rangeOfString:firstRange].location != NSNotFound, "first segment byte range");
        CHECK([media hasSuffix:@"#EXT-X-ENDLIST\n"], "VOD playlist ends");
        CHECK([media componentsSeparatedByString:@"#EXTINF:"].count == 5, "one EXTINF per segment");

        // AV1 (YouTube's AV1 DASH files; an iPhone 15 Pro and later play it in Apple's HLS): from av1C
        SFFMP4Track *av1 = Parse(Fixture(@"video-av1.mp4"), &maxRead, &why);
        CHECK(av1 && av1.isVideo, [[@"AV1 parsed: " stringByAppendingString:why ?: @""] UTF8String]);
        CHECK([av1.codec isEqualToString:@"av01.0.00M.08"], [[@"AV1 Main level 2.0 8 bit codec string, got " stringByAppendingString:av1.codec ?: @"nil"] UTF8String]);
        CHECK(av1.width == 96 && av1.height == 54 && av1.segments.count == 4, "AV1 picture size and segments");
        CHECK([SFHLSMasterPlaylist(av1, at, @"v.m3u8", @"a.m3u8") rangeOfString:@"CODECS=\"av01.0.00M.08,mp4a.40.2\""].location != NSNotFound, "master names AV1 + AAC");

        // refused: a truncated header, a WebM file, a track without sidx
        CHECK(!Parse([v subdataWithRange:NSMakeRange(0, 400)], &maxRead, &why), "truncated moov refused");
        uint8_t webm[16] = {0x1a, 0x45, 0xdf, 0xa3, 0x9f, 0x42, 0x86, 0x81, 0x01, 0x42, 0xf7, 0x81, 0x01, 0x42, 0xf2, 0x81};
        CHECK(!Parse([NSData dataWithBytes:webm length:sizeof webm], &maxRead, &why), "WebM refused");
        NSMutableData *noSidx = [[v subdataWithRange:NSMakeRange(0, 742)] mutableCopy];
        [noSidx appendData:[v subdataWithRange:NSMakeRange(830, v.length - 830)]];
        CHECK(!Parse(noSidx, &maxRead, &why) && [why rangeOfString:@"sidx"].location != NSNotFound, "no sidx refused");
    }
    if (fails) { fprintf(stderr, "%d check(s) failed\n", fails); return 1; }
    printf("webhls ok\n");
    return 0;
}
