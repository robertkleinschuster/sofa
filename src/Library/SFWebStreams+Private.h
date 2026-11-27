// Shared by SFWebStreams.m (opening, reports, lifetime) and SFWebStreams+Serve.m (the media routes).
#import "SFWebStreams.h"
#import "SFApp.h"
#import "SFWebHLS.h"
#import "SFWebTranscode.h"

typedef NS_ENUM(NSInteger, SFWebStreamKind) {
    SFWebStreamDash,       // a video + audio pair of fragmented MP4 tracks -> HLS (SFWebHLS)
    SFWebStreamHLS,        // a local HLS playlist (media proxy, engine lives) -> relayed, URIs rewritten
    SFWebStreamFile,       // a local route serving one file (media proxy, the store)
    SFWebStreamLocalFile,  // a file on this disk (an old download)
    SFWebStreamSegmented,  // cut into HLS segments on demand, tracks copied or encoded (SFWebTranscode)
};

@interface SFWebStream : NSObject
@property (nonatomic, copy) NSString *identifier, *device;
@property (nonatomic, strong) SFItem *item;
@property (nonatomic, copy) NSDictionary *source;      // the resolver's stream description (SFMPVSourceFor)
@property (nonatomic) SFWebStreamKind kind;
@property (nonatomic, strong) NSURL *upstream;         // file: its route or path; HLS: the root playlist
@property (nonatomic, strong) NSURL *video, *audio;    // dash: the tracks' routes
@property (nonatomic, copy) NSString *master, *videoPlaylist, *audioPlaylist;   // dash
@property (nonatomic, copy) NSArray *prefixes;         // local URLs this stream may reach (route prefixes)
@property (nonatomic, strong) NSURL *proxied;          // a media proxy session opened for it (released at the end)
@property (nonatomic, strong) SFWebTranscode *transcode;   // segmented: its session (closed at the end)
@property (nonatomic) BOOL live, saved, everSaved;
@property (atomic) BOOL paused;                        // its last report said "paused" (it may stay unused longer)
@property (atomic) NSTimeInterval lastUsed;
@end

@interface SFWebStreams ()
- (SFWebStream *)streamWithID:(NSString *)identifier;   // any queue; notes it as used
- (double)startOf:(SFWebStream *)s;                      // where its playback begins (the stored position, as the TV resumes)
- (void)opened:(SFWebStream *)s app:(Class<SFApp>)app duration:(NSTimeInterval)duration
          done:(void (^)(NSDictionary *, NSInteger, NSString *, NSString *))done;
@end

@interface SFWebStreams (Transcode)   // SFWebStreams+Transcode.m
// `s` (video + audio: paths or local URLs; audio nil: in the video's input) as HLS segments for a browser
// decoding `formats`, when the segmenter is needed and can help: done(YES) with `s` segmented (its
// session's init made - the encoder works). done(NO, asIs): the source plays as it is (asIs) or the
// segmenter can't help (*why): the caller goes on as before. `reencode`: the codec to encode the video
// into even where the browser plays it as it is (SFWebTranscode's planVideo). Main thread.
- (void)segment:(SFWebStream *)s video:(NSString *)video audio:(NSString *)audio keyframes:(NSArray *)keyframes
        formats:(NSSet *)formats reencode:(NSString *)reencode done:(void (^)(BOOL segmented, BOOL asIs, NSString *why))done;
@end
