// sources: src/Library/SFHLSPlaylist.m
// flags: -Isrc/Library
// Pure HLS playlist reading (SFHLSPlaylist): attributes, absolute URIs - also of a URI that does not
// parse (a nil reached an array: an exception, the app gone) -, a media playlist's resources, the
// variant a download takes and the master reduced to it.
#import "SFHLSPlaylist.h"
BOOL SFDevMode = YES;   // SFCore (linked to every unit test)

static int bad = 0;
static void expect(BOOL c, const char *what) { printf("%s %s\n", c ? "ok  " : "FAIL", what); fflush(stdout); if (!c) bad++; }

int main(void) { @autoreleasepool {
    NSString *base = @"https://cdn.example/vod/master.m3u8?token=1";

    NSDictionary *a = SFHLSAttributes(@"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud,1\",NAME=\"Deutsch\",DEFAULT=YES,URI=\"a/index.m3u8\"");
    expect([a[@"TYPE"] isEqual:@"AUDIO"] && [a[@"GROUP-ID"] isEqual:@"aud,1"] && [a[@"URI"] isEqual:@"a/index.m3u8"], "attributes: plain and quoted (a comma inside quotes)");
    expect(SFHLSAttributes(@"#EXTM3U").count == 0, "a tag without attributes: none");

    expect([SFHLSAbsolute(@"seg1.ts", base) isEqual:@"https://cdn.example/vod/seg1.ts"], "relative against the playlist");
    expect([SFHLSAbsolute(@"https://other.example/x.ts", base) isEqual:@"https://other.example/x.ts"], "absolute stays");
    NSString *sp = SFHLSAbsolute(@"seg 2.ts", base);
    expect([sp isEqual:@"https://cdn.example/vod/seg%202.ts"], "a space: escaped as players do");
    expect(SFHLSAbsolute(@"%%bad%%", base) != nil, "a URI that does not parse even escaped: kept, never nil");
    expect(SFHLSAbsolute(nil, base) == nil, "no URI: nil");

    NSString *media = @"#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXT-X-MAP:URI=\"init.mp4\"\n"
                       "#EXTINF:4,\nseg1.m4s\n#EXTINF:4,\nseg 2.m4s\n#EXTINF:4,\n%%bad%%\n#EXT-X-ENDLIST\n";
    NSArray *res = SFHLSResources(media, base);
    expect(res.count == 5 && [res containsObject:@"https://cdn.example/vod/key.bin"] && [res containsObject:@"https://cdn.example/vod/init.mp4"],
           "resources: segments, key and init section - a broken URI among them does not end the list");

    NSString *master = @"#EXTM3U\n"
        "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a1\",NAME=\"de\",DEFAULT=YES,URI=\"audio/de.m3u8\"\n"
        "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a2\",NAME=\"de\",DEFAULT=YES,URI=\"audio2/de.m3u8\"\n"
        "#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=640x360,AUDIO=\"a1\"\nv360.m3u8\n"
        "#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,AUDIO=\"a1\"\nv1080.m3u8\n"
        "#EXT-X-STREAM-INF:BANDWIDTH=9000000,RESOLUTION=3840x2160,AUDIO=\"a2\"\nv2160.m3u8\n"
        "#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=100000,URI=\"iframes.m3u8\"\n";
    long long bw = 0;
    NSArray *v = SFHLSChooseVariant(master, base, &bw);
    expect(v.count == 2 && [v[0] isEqual:@"https://cdn.example/vod/v1080.m3u8"] && [v[1] isEqual:@"https://cdn.example/vod/audio/de.m3u8"] && bw == 5000000,
           "the best variant up to 1080p, with its group's audio");
    NSString *one = SFHLSOneVariant(master, base);
    expect([one rangeOfString:@"v1080.m3u8"].location != NSNotFound && [one rangeOfString:@"v360.m3u8"].location == NSNotFound
           && [one rangeOfString:@"v2160.m3u8"].location == NSNotFound && [one rangeOfString:@"audio2/"].location == NSNotFound
           && [one rangeOfString:@"I-FRAME"].location == NSNotFound, "the master for the player: only that variant and its audio");
    expect([SFHLSOneVariant(@"#EXTM3U\n#EXTINF:4,\nseg.ts\n", base) isEqual:@"#EXTM3U\n#EXTINF:4,\nseg.ts\n"], "no variants: the playlist as it is");
    return bad ? 1 : 0;
} }
