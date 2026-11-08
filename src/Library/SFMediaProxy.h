// SFMediaProxy - the mediatheks' media through the media store - progressive files (ZDF, ARD, CCC)
// here, HLS (ORF) in SFMediaProxy+HLS.m
// (docs/media-store.md): the player reads a local URL, every byte passes the store - what is on disk
// comes from there, the rest from the source in one streamed range request per gap (curl: every host,
// TLS 1.3 included), written to disk on the way. An item complete in the store plays from a local URL
// without its source (offline too); a download fills the store the same way, paced.
// A file is a track of its item: key "file:<item>:<host+path hash>:<length>" (a URL's token query
// does not change the identity); the item's manifest (kind "file") names it and its subtitles.
#import "SFCore.h"

@interface SFMediaProxy : NSObject
+ (instancetype)shared;
+ (BOOL)canServe:(NSURL *)url;   // an http(s) file or HLS playlist (not loopback)
// A local URL serving the file `url` of item `item` through the store
- (NSURL *)localURLFor:(NSURL *)url item:(NSString *)item;
// The item complete in the store as a local URL; *subs: its stored subtitles as player source entries
// ({lang, kind, name, url}). nil: not complete, or not a file item
- (NSURL *)storedURLFor:(NSString *)item subs:(NSArray **)subs;
// What of the item playing from `url` (a URL of this proxy) is on disk, as time ranges @[@[start s,
// end s]] - exact only: HLS by its segments' durations (video and audio rendition both); nil when
// not known (a progressive file: bytes -> time needs the container's index). done on the main queue.
- (void)storedRangesFor:(NSURL *)url done:(void (^)(NSArray *ranges))done;
// A download: the file and its subtitles (player source entries) into the store, paced at 3x the
// playback rate (`duration` in s; 0: unpaced); progress 0..1 and done(nil | error) on the main queue.
// The returned block cancels.
- (dispatch_block_t)fill:(NSURL *)url item:(NSString *)item subs:(NSArray *)subs duration:(double)duration
                progress:(void (^)(double p))progress done:(void (^)(NSError *e))done;
@end
