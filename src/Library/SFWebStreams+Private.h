// Shared by SFWebStreams.m (opening, reports, lifetime) and SFWebStreams+Serve.m (the media routes).
#import "SFWebStreams.h"
#import "SFWebHLS.h"

typedef NS_ENUM(NSInteger, SFWebStreamKind) {
    SFWebStreamDash,       // a video + audio pair of fragmented MP4 tracks -> HLS (SFWebHLS)
    SFWebStreamHLS,        // a local HLS playlist (media proxy, engine lives) -> relayed, URIs rewritten
    SFWebStreamFile,       // a local route serving one file (media proxy, the store)
    SFWebStreamLocalFile,  // a file on this disk (an old download)
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
@property (nonatomic) BOOL live, saved, everSaved;
@property (atomic) NSTimeInterval lastUsed;
@end

@interface SFWebStreams ()
- (SFWebStream *)streamWithID:(NSString *)identifier;   // any queue; notes it as used
@end
