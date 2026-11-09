// sources: src/Library/SFPrebuffer.m src/Library/SFPrebufferPlan.m src/Core/SFModel.m
// flags: -Isrc/Library -Isrc/Player -Isrc/Core -Isrc/Framework
// Production coordinator with deterministic provider/network/download state, no media traffic.
#import "SFPrebuffer.h"
#import "SFPrebufferReader.h"
#import "SFApp.h"
#import "SFStore.h"
#import "SFNet.h"
#import "SFDownloads.h"
#import "SFMediaProxy.h"
BOOL SFDevMode=YES;
static BOOL online=YES,manual=NO;
static NSTimeInterval pauseUntil;
static NSMutableArray *starts;
static NSMutableDictionary *pending;
static int bad;
static void expect(BOOL b,const char *m){printf("%s %s\n",b ? "ok" : "FAIL",m);if(!b)bad++;}
static BOOL until(BOOL (^ready)(void),double t){NSDate *end=[NSDate dateWithTimeIntervalSinceNow:t];while(!ready() && end.timeIntervalSinceNow>0)[[NSRunLoop currentRunLoop]runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];return ready();}
@interface SFPrebuffer (Tests)
- (void)pump;- (void)sleep:(NSNotification *)n;- (void)wake:(NSNotification *)n;
@end
@interface FixtureCoordinator:SFPrebuffer
@property BOOL fixtureSleeping;
@end
@implementation FixtureCoordinator
- (BOOL)isSleeping{return self.fixtureSleeping;}
@end
@interface FixtureApp:NSObject @end
@implementation FixtureApp
+ (void)prepareItem:(SFItem *)item position:(double)p done:(void (^)(NSURL *,dispatch_block_t))done{
 [starts addObject:item.identifier];pending[item.identifier]=[done copy];
}
@end
@implementation SFAppRegistry
+ (Class)appForItem:(SFItem *)i{return [FixtureApp class];}
+ (Class)appForRef:(NSString *)s{return [FixtureApp class];}
@end
NSTimeInterval SFBackgroundPausedUntil(NSString *r){return pauseUntil;}
NSDictionary *SFMPVSourceFor(NSURL *u){return nil;}
@implementation SFStore
+ (instancetype)shared{static SFStore *s;if(!s)s=[SFStore new];return s;}
- (NSArray *)history:(NSInteger)n{return @[];}
@end
NSString *const SFNetOnlineDidChangeNotification=@"fixture-online";
@implementation SFNet
+ (BOOL)isOnline{return online;}
@end
NSString *const SFDownloadsDidChangeNotification=@"fixture-downloads";
NSString *const SFDownloadsStorageDidChangeNotification=@"fixture-storage";
@implementation SFDownloads
+ (instancetype)shared{static SFDownloads *s;if(!s)s=[SFDownloads new];return s;}
- (NSArray *)active{return manual ? @[@1] : @[];}
- (BOOL)storageFull{return NO;}
- (unsigned long long)freeBytes{return 1ULL<<40;}
- (unsigned long long)storageReserve{return 1ULL<<20;}
@end
@implementation SFMediaProxy
+ (instancetype)shared{static SFMediaProxy *s;if(!s)s=[SFMediaProxy new];return s;}
+ (BOOL)canServe:(NSURL *)u{return NO;}
- (NSURL *)localURLFor:(NSURL *)u item:(NSString *)s{return u;}
- (void)releaseURL:(NSURL *)u{}
@end
@implementation SFPrebufferRead
@end
@implementation SFPrebufferReader
+ (NSDictionary *)readURL:(NSURL *)u audio:(NSURL *)a position:(double)p request:(SFPrebufferRead *)r{return @{};}
@end
static SFItem *item(NSString *s){SFItem *i=[SFItem new];i.kind=SFItemVideo;i.identifier=s;i.resolverRef=s;return i;}
static void drain(void){NSArray *callbacks=pending.allValues;[pending removeAllObjects];for(void (^f)(NSURL *,dispatch_block_t) in callbacks)f(nil,nil);}
int main(void){@autoreleasepool{
 setenv("SOFA_PREBUFFER_SPACING","0.15",1);setenv("SOFA_PREBUFFER_COOLDOWN","0.4",1);
 starts=[NSMutableArray new];pending=[NSMutableDictionary new];NSObject *owner=[NSObject new];
 FixtureCoordinator *c=[FixtureCoordinator new];SFItem *a=item(@"fixture:a"),*b=item(@"fixture:b");
 [c offer:@[a] focused:a owner:owner];expect(starts.count==1,"first focus starts immediately");
 [c offer:@[b] focused:b owner:owner];expect(starts.count==1,"focus replacement respects spacing");
 expect(until(^BOOL{return starts.count==2;},1),"replacement wakes automatically without another offer");
 expect([starts.lastObject isEqual:b.identifier],"only latest focused candidate starts");
 [c leave:owner];drain();[starts removeAllObjects];
 c=[FixtureCoordinator new];online=NO;
 [c offer:@[a] focused:a owner:owner];expect(starts.count==0,"offline gate blocks candidates");
 online=YES;[[NSNotificationCenter defaultCenter]postNotificationName:SFNetOnlineDidChangeNotification object:nil];
 expect(until(^BOOL{return starts.count==1;},.5),"network recovery wakes pending candidate");
 [c leave:owner];drain();[starts removeAllObjects];
 c=[FixtureCoordinator new];manual=YES;
 [c offer:@[a] focused:a owner:owner];expect(starts.count==0,"manual downloads have priority");
 manual=NO;[[NSNotificationCenter defaultCenter]postNotificationName:SFDownloadsDidChangeNotification object:nil];
 expect(until(^BOOL{return starts.count==1;},.5),"manual completion wakes pending candidate");
 [c leave:owner];drain();[starts removeAllObjects];
 c=[FixtureCoordinator new];c.fixtureSleeping=YES;[c sleep:nil];
 [c offer:@[a] focused:a owner:owner];expect(starts.count==0,"sleep blocks pending candidate");
 c.fixtureSleeping=NO;[c wake:nil];expect(starts.count==1,"display wake rechecks pending candidate");
 [c leave:owner];drain();[starts removeAllObjects];
 c=[FixtureCoordinator new];pauseUntil=[NSDate date].timeIntervalSince1970+.2;
 [c offer:@[a] focused:a owner:owner];expect(starts.count==0,"provider pause is respected");
 expect(until(^BOOL{return starts.count==1;},1),"provider pause expiry wakes without new offers");
 [c offer:@[b] focused:b owner:owner];[c leave:owner];drain();NSUInteger before=starts.count;
 until(^BOOL{return NO;},.4);expect(starts.count==before,"leaving invalidates deferred work");
 return bad ? 1 : 0;
}}
