// Shared between SFMediaProxy.m (progressive files) and SFMediaProxy+HLS.m (HLS).
#import "SFMediaProxy.h"
#import "SFLocalHTTP.h"
#import "SFDownloads.h"
#import "SFMediaStore.h"

// One served source of an item. File: one track (`url` nil = stored: the store or nothing). HLS: its
// playlists and resources by index - every resource a track of the item.
@interface SFProxySession : NSObject
@property (nonatomic, copy) NSString *sid, *item, *url, *key, *mime;
@property (nonatomic) long long total;           // file: 0 until the source told it
@property (nonatomic, copy) NSArray *subs;       // stored sessions: subtitle track keys by index
@property (nonatomic) BOOL hls, stored, vod;     // vod: a media playlist ended (#EXT-X-ENDLIST) - its resources are kept
@property (nonatomic, strong) NSMutableArray *playlists, *resources;   // origin URLs by index (HLS)
@property (nonatomic, strong) NSMutableDictionary *playlistIndex, *resourceIndex;   // origin URL -> index
@property (nonatomic, copy) NSArray *storedPlaylists;   // stored HLS: @[@{text, base}] by index; 0 = the root
@end

static inline SFMediaStore *SFProxyStore(void) { return [SFDownloads shared].mediaStore; }
NSString *SFProxyHash(NSString *s);   // 16 hex chars of SHA-1

@interface SFMediaProxy ()
@property (nonatomic, readonly) dispatch_queue_t queue;   // the server's (sessions, exchanges)
@property (nonatomic, readonly) uint16_t port;
- (NSString *)addSession:(SFProxySession *)s;             // its base URL (http://127.0.0.1:<port>/<f|h>/<sid>)
- (NSArray *)storedSubs:(NSDictionary *)manifest session:(SFProxySession *)s base:(NSString *)base;   // player entries
- (NSArray *)fillSubs:(NSArray *)subs item:(NSString *)item prefix:(NSString *)prefix cancelled:(BOOL (^)(void))cancelled;
@end

@interface SFMediaProxy (HLS)
+ (BOOL)isPlaylist:(NSURL *)url;
- (NSURL *)hlsURLFor:(NSURL *)url item:(NSString *)item;
- (NSURL *)storedHLSFor:(NSString *)item manifest:(NSDictionary *)m subs:(NSArray **)subs;
- (void)serveHLS:(SFHTTPExchange *)x session:(SFProxySession *)s;   // on the queue
- (dispatch_block_t)fillHLS:(NSURL *)url item:(NSString *)item subs:(NSArray *)subs
                   progress:(void (^)(double))progress done:(void (^)(NSError *))done;
@end
