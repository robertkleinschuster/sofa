// Standalone integration: real YT media/store/fill categories and libmpv, fake browser RPC only.
#import "SFYTEngine+Private.h"
#import "SFDownloads.h"
#import "SFMediaStore.h"
#import "SFPrebufferReader.h"
#import "SFJSON.h"
BOOL SFDevMode=YES;
static SFMediaStore *gStore;
static NSDictionary *gFiles;
static NSUInteger gFetched;
static NSDictionary *gAnswer;
static NSMutableSet *gFirstReads;
static int bad;
static void expect(BOOL ok,const char *msg) {printf("%s %s\n",ok ? "ok" : "FAIL",msg);fflush(stdout);if(!ok)bad++;}
NSError *SFError(NSString *m){return [NSError errorWithDomain:@"fixture" code:1 userInfo:@{NSLocalizedDescriptionKey:m}];}
// The download/store owner is isolated; no real application database, settings or browser.
@implementation SFDownloads
+ (instancetype)shared {static SFDownloads *d;static dispatch_once_t o;dispatch_once(&o,^{d=[SFDownloads new];});return d;}
- (SFMediaStore *)mediaStore {return gStore;}
@end
@implementation SFYTEngine {
 dispatch_queue_t _fixtureQueue; SFLocalHTTP *_fixtureServer;
}
+ (instancetype)shared {static SFYTEngine *e;static dispatch_once_t o;dispatch_once(&o,^{e=[SFYTEngine new];});return e;}
- (instancetype)init {if((self=[super init])) {
 _fixtureQueue=dispatch_queue_create("yt-prebuffer-fixture",DISPATCH_QUEUE_SERIAL);
 __weak SFYTEngine *w=self;
 _fixtureServer=[[SFLocalHTTP alloc] initWithName:@"yt-prebuffer-fixture" queue:_fixtureQueue maxBody:0 handler:^(SFHTTPExchange *x){[w serveSession:x];}];
 [_fixtureServer startPreferringPort:0];
}return self;}
- (dispatch_queue_t)queue {return _fixtureQueue;}
- (NSString *)mediaBase {return [NSString stringWithFormat:@"http://127.0.0.1:%u",_fixtureServer.port];}
- (void)request:(NSString *)method args:(NSArray *)args timeout:(NSTimeInterval)timeout done:(void (^)(id,NSError *))done {
 dispatch_async(_fixtureQueue,^{
   if(![method isEqual:@"read"]){done(nil,SFError(@"unexpected RPC"));return;}
   NSString *key=args[1];NSData *data=gFiles[key];NSUInteger at=[args[2] unsignedIntegerValue],max=[args[3] unsignedIntegerValue];
   if(!data || at>=data.length){done(nil,SFError(@"source offline or invalid read"));return;}
   NSUInteger n=MIN(max,data.length-at);
   void (^deliver)(void)=^{
     gFetched+=n;
     done(@{@"data":[data subdataWithRange:NSMakeRange(at,n)],@"total":@(data.length),@"id":[@"fixture:" stringByAppendingString:key],@"mimeType":[key isEqual:@"video"] ? @"video/mp4" : @"audio/mp4"},nil);
   };
   // Real SABR startup can need token setup plus ~5 s to its first segment.
   // A five-second HTTP timeout aborts before either track has useful bytes.
   if(![gFirstReads containsObject:key]) {
     [gFirstReads addObject:key];
     dispatch_after(dispatch_time(DISPATCH_TIME_NOW,6*NSEC_PER_SEC),self->_fixtureQueue,deliver);
   } else deliver();
 });
}
- (void)open:(NSString *)vid background:(BOOL)bg stored:(BOOL)stored done:(void (^)(NSDictionary *,NSError *))done {
 NSDictionary *r=stored ? [self storedAnswer:vid] : nil;done(r ?: gAnswer,nil);
}
- (void)closeSession:(NSString *)sid {} // fake RPC has no external browser resources
@end
static BOOL until(BOOL (^ready)(void),double seconds) {
 NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
 while(!ready() && end.timeIntervalSinceNow>0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
 return ready();
}
int main(int argc,char **argv){@autoreleasepool {
 if(argc!=4)return 2;
 gFirstReads=[NSMutableSet new];
 NSString *dir=[NSString stringWithUTF8String:argv[3]];
 gStore=[[SFMediaStore alloc] initWithDirectory:dir];
 gFiles=@{@"video":[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]],@"140":[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[2]]]};
 SFYTEngine *engine=[SFYTEngine shared];NSString *base=engine.mediaBase;
 NSString *video=[base stringByAppendingString:@"/s/fixture/video"],*audio=[base stringByAppendingString:@"/s/fixture/audio/140"];
 gAnswer=@{@"id":@"fixture",@"sid":@"fixture",@"video":video,@"audio":audio,@"duration":@180,
   @"tracks":@{@"video":@{@"id":@"fixture:video",@"total":@([gFiles[@"video"] length]),@"mimeType":@"video/mp4"},
                @"140":@{@"id":@"fixture:140",@"total":@([gFiles[@"140"] length]),@"mimeType":@"audio/mp4"}}};
 [engine noteOpened:gAnswer];
 __block BOOL finished=NO;__block NSDictionary *result;
 SFPrebufferRead *request=[SFPrebufferRead new];
 dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0),^{
   NSDictionary *r=[SFPrebufferReader readURL:[NSURL URLWithString:video] audio:[NSURL URLWithString:audio] position:70 request:request];
   SFMain(^{result=r;finished=YES;});
 });
 expect(until(^BOOL{return finished;},40),"YouTube-shaped predictive reader finishes");request.cancelled=YES;
 expect([result[@"reason"] isEqual:@"bounded"] && fabs([result[@"position"] doubleValue]-70)<1,"separate video/audio resume at 70 s");
 [gStore sync];
 long long buffered=[gStore bytesOfItem:@"yt:fixture"],total=[gFiles[@"video"] length]+[gFiles[@"140"] length];
 expect(buffered>0 && buffered<total,"predictive bytes are partial in the actual persistent media store");
 printf("buffered %lld / %lld bytes\n",buffered,total);fflush(stdout);
 NSUInteger before=gFetched;
 __block BOOL filled=NO;__block NSError *fillError;
 dispatch_block_t cancel=[engine fill:@"fixture" progress:^(double p){} done:^(NSDictionary *r,NSError *e){fillError=e;filled=YES;}];
 expect(until(^BOOL{return filled;},80),"manual fill finishes through the production filler");
 if(!filled)cancel();
 [gStore sync];
 expect(!fillError && [gStore itemIsComplete:@"yt:fixture"],"manual fill completes exactly the same buffer");
 expect(gFetched-before==(NSUInteger)(total-buffered),"manual fill fetches only the missing byte ranges");
 gFiles=nil;
 NSDictionary *stored=[engine storedAnswer:@"fixture"];
 expect(stored!=nil && [stored[@"stored"] boolValue],"complete buffer opens as a stored YouTube session");
 before=gFetched;finished=NO;
 SFPrebufferRead *offline=[SFPrebufferRead new];
 dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0),^{
   NSDictionary *r=[SFPrebufferReader readURL:[NSURL URLWithString:stored[@"video"]] audio:[NSURL URLWithString:stored[@"audio"]] position:70 request:offline];
   SFMain(^{result=r;finished=YES;});
 });
 expect(until(^BOOL{return finished;},35),"stored session demuxes offline");offline.cancelled=YES;
 expect([result[@"reason"] isEqual:@"bounded"] && gFetched==before,"offline reader uses persistent bytes without browser RPC");
 SFMediaStore *reopened=[[SFMediaStore alloc] initWithDirectory:dir];
 expect([reopened itemIsComplete:@"yt:fixture"] && [reopened bytesOfItem:@"yt:fixture"]==total,"one completed buffer persists across store reopen");
 return bad ? 1 : 0;
}}
