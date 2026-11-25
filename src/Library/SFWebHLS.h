// SFWebHLS - an HLS presentation of a pair of fragmented-MP4 tracks for a web browser (Sofa im Browser,
// docs/pwa.md): YouTube's DASH tracks (byte-identical files, docs/youtube-engine.md) become a master
// playlist with the audio as its own rendition and one media playlist per track whose segments are
// byte ranges of the track - exactly the subsegments its `sidx` names, the `moov` as EXT-X-MAP. Every
// browser plays that natively (Safari, iOS) or through hls.js. Pure: the bytes come from a reader,
// codecs and timing from the boxes (no guessing: a track without them is refused).
#import <Foundation/Foundation.h>

@interface SFFMP4Track : NSObject
@property (nonatomic, readonly) long long initEnd;       // end of ftyp + moov (the initialization section)
@property (nonatomic, readonly, copy) NSArray *segments; // @[@[offset, length, seconds]] in order
@property (nonatomic, readonly, copy) NSString *codec;   // RFC 6381: "avc1.64002a", "mp4a.40.2"
@property (nonatomic, readonly) int width, height;       // video only (0 for audio)
@property (nonatomic, readonly) double duration;         // seconds, the segments' sum
@property (nonatomic, readonly) BOOL isVideo;
// Walks the top-level boxes from 0 with `read` (bytes [offset, offset + length), fewer at the end;
// nil = unreadable) - only header ranges, up to the sidx. nil and *why when it is no such track.
+ (instancetype)trackWithReader:(NSData *(^)(long long offset, NSUInteger length))read error:(NSString **)why;
@end

// The master playlist (video variant + audio rendition) and a track's media playlist; the URIs are
// written as given (relative to the playlists' own location).
NSString *SFHLSMasterPlaylist(SFFMP4Track *video, SFFMP4Track *audio, NSString *videoPlaylist, NSString *audioPlaylist);
NSString *SFHLSMediaPlaylist(SFFMP4Track *track, NSString *trackURI);
