// sources: src/Library/SFPrebufferPlan.m src/Core/SFModel.m
// flags: -Isrc/Library -Isrc/Core -Isrc/Framework
#import "SFPrebufferPlan.h"
#import <math.h>
BOOL SFDevMode = NO;
// Registry lookup is not used by the pure selection policy.
@interface SFAppRegistry : NSObject @end
@implementation SFAppRegistry @end
static int bad;
static void expect(BOOL ok, const char *msg) { printf("%s %s\n",ok ? "ok" : "FAIL",msg); if(!ok) bad++; }
static SFItem *item(NSString *ident, NSString *channel) {
 SFItem *i=[SFItem new]; i.identifier=ident;i.kind=SFItemVideo;i.source=@"test";i.channel=channel;i.duration=1000;return i;
}
int main(void) { @autoreleasepool {
 SFItem *a=item(@"test:a",@"A"),*b=item(@"test:b",@"B"),*c=item(@"test:c",@"A"),*d=item(@"test:d",@"C"),*live=item(@"test:live",@"A");live.kind=SFItemLive;
 NSArray *history=@[@{@"item":b,@"updated":@10000,@"pos":@400,@"watched":@NO},@{@"item":a,@"updated":@9000,@"pos":@0,@"watched":@YES}];
 NSArray *r=[SFPrebufferPlan candidates:@[a,b,c,d,live,c] focused:c history:history now:10001];
 expect(r.count==3,"at most three useful, unique candidates");
 expect([r[0][@"item"] identifier]==c.identifier,"focused suggestion first");
 expect([r[1][@"item"] identifier]==b.identifier && [r[1][@"position"] doubleValue]==400,"recent unfinished item at its actual resume position");
 expect([r[2][@"item"] identifier]==d.identifier,"watched/live/duplicate items excluded");
 r=[SFPrebufferPlan candidates:@[d,c] focused:nil history:@[@{@"item":a,@"updated":@10000,@"pos":@0,@"watched":@YES}] now:10001];
 expect([r[0][@"item"] identifier]==c.identifier,"usage affinity can outweigh suggestion order");
 r=[SFPrebufferPlan candidates:@[] focused:a history:history now:10001];
 expect([r[0][@"position"] doubleValue]==0,"focused watched item prepares a replay from zero");
 r=[SFPrebufferPlan candidates:@[b] focused:b history:@[@{@"item":b,@"pos":@(NAN),@"updated":@10000}] now:10001];
 expect([r[0][@"position"] doubleValue]==0,"invalid resume position never reaches the fetcher");
 expect(![SFPrebufferPlan candidates:@[] focused:nil history:@[] now:10001].count,"empty input does no background work");
 return bad ? 1 : 0;
} }
