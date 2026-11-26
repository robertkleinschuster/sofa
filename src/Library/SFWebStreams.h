// SFWebStreams - playbacks of Sofa im Browser (docs/pwa.md). A play resolves an item as the TV does
// (the owning app; `resolveForBrowser:` where the app has a browser format) and opens it through
// Sofa's own local routes - the media proxy and its store, the YouTube engine's sessions, a
// download's file - never the source. The browser gets a capability path /m/<stream>/… (128-bit
// random) that serves only that stream: a DASH pair as an HLS presentation (SFWebHLS), an HLS
// playlist with its local URIs rewritten, or a file, all with Range. Player state reports save the
// position in the store (the TV's rule) and reach the app's view reporting. A stream ends when the
// browser says so, after 10 minutes unused, or when the same device opens a fourth. What the browser
// can't play as it is goes through the segmenter (SFWebTranscode; docs/pwa.md §8).
#import "SFModel.h"
#import "SFLocalHTTP.h"

@interface SFWebStreams : NSObject
+ (instancetype)shared;
// Main thread. `formats`: the codecs the browser decodes in MP4 (SFAVBrowserCodec names - avc1, vp09,
// av01, hvc1, mp4a, opus). done(answer, 200, nil) or (nil, status, message for the viewer):
// answer {stream, kind: hls|file, url (path under the server), start (s), duration, live, title, segmented?}
- (void)play:(SFItem *)item device:(NSString *)device formats:(NSSet *)formats
        done:(void (^)(NSDictionary *answer, NSInteger status, NSString *message))done;
// Main thread. {state: playing|paused|buffering|ended|closed, position, duration, lactMs}. 404 = no such
// stream (of this device; device nil: asked on the stream's capability path, which is its own proof).
- (NSInteger)report:(NSString *)streamID device:(NSString *)device state:(NSDictionary *)state;
// Main thread. Ends a device's playbacks of an item as its "closed" would (the item moved to the TV:
// one player per video and person - the browser stops its own stream for it). Returns how many.
- (NSUInteger)endItem:(NSString *)identifier device:(NSString *)device why:(NSString *)why;
- (NSUInteger)countForTesting;
@end

@interface SFWebStreams (Serve)   // SFWebStreams+Serve.m
// The server's queue: GET|HEAD /m/<stream>/<rest...>
- (void)serve:(SFHTTPExchange *)x stream:(NSString *)streamID rest:(NSArray *)rest;
@end
