// A bounded, silent demux reader. Caller supplies store-backed URLs, never a UI player.
#import <Foundation/Foundation.h>
@interface SFPrebufferRead : NSObject
@property (atomic) BOOL cancelled;
@property (nonatomic, readonly) NSString *budgetToken;
@end
@interface SFPrebufferReader : NSObject
// Runs synchronously on a worker queue. No rendering, audio device, history or playback reporting.
// Limits: 12 s read-ahead, 16 MiB forward cache, no backward cache, 30 s wall time.
+ (NSDictionary *)readURL:(NSURL *)url audio:(NSURL *)audio position:(double)position request:(SFPrebufferRead *)request;
@end
