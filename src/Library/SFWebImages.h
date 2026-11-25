// SFWebImages - pictures for Sofa im Browser (docs/pwa.md): the same path the TV's tiles load through
// (SFImageCache: its disk cache, a source's own client such as YouTube's engine, the curl bridge,
// local files, SVG and WebP), encoded for the browser at the size it shows them. A picture URL is
// signed (HMAC of the source with a key kept in the settings), handed out only inside authenticated
// answers - the route is no open proxy and reads no file it was not given.
#import "SFModel.h"

@interface SFWebImages : NSObject
// "/img/<signature>?u=<source>" for a source (path or URL); nil for none
+ (NSString *)pathFor:(NSString *)source;
+ (BOOL)signature:(NSString *)sig matches:(NSString *)source;
// The picture at about `width` pixels: JPEG, or PNG when it has transparency (logos). done on main;
// nil when it can't be loaded.
+ (void)imageFor:(NSString *)source width:(NSUInteger)width done:(void (^)(NSData *data, NSString *mime))done;
@end
