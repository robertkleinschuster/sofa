// sources: src/Core/SFCurl+Stream.m src/Core/SFCurl.m src/Core/SFHTTPBudget.m src/Core/SFLocalHTTP.m src/Core/SFWebSocket.m
// flags: -I/opt/local/include -L/opt/local/lib -lcurl
#import "SFCurl.h"
#import "SFHTTPBudget.h"
#import "SFLocalHTTP.h"
BOOL SFDevMode=NO;
NSString *SFNativeUserAgent(void) { return @"Sofa local budget test"; }
NSError *SFError(NSString *m) { return [NSError errorWithDomain:@"test" code:1 userInfo:@{NSLocalizedDescriptionKey:m}]; }
static int bad;
static void expect(BOOL b,const char *m) { printf("%s %s\n",b ? "ok" : "FAIL",m);if(!b)bad++; }
int main(void) { @autoreleasepool {
 NSData *body=[NSMutableData dataWithLength:2*1024*1024];
 __block uint16_t port=0;
 SFLocalHTTP *server=[[SFLocalHTTP alloc] initWithName:@"curl-budget-test" queue:dispatch_queue_create("curl-budget-test",DISPATCH_QUEUE_SERIAL) maxBody:0 handler:^(SFHTTPExchange *x) {
   if([x.request.pathParts.firstObject isEqual:@"redirect"]) {
     [x begin:302 headers:@{@"Content-Length":@"0",@"Location":[NSString stringWithFormat:@"http://127.0.0.1:%u/body",port]}];[x finish];
   } else if([x.request.pathParts.firstObject isEqual:@"stall"]) {
     x.onClose=^{ (void)x; }; // own exchange until the cancelled reader closes it
     [x begin:200 headers:@{@"Content-Length":@"2097152"}];
   } else [x respond:200 type:@"application/octet-stream" body:body];
 }];
 expect([server startPreferringPort:0],"local fixture server starts");port=server.port;
 NSString *url=[NSString stringWithFormat:@"http://127.0.0.1:%u/redirect",port];
 NSString *token=[SFHTTPBudget open:64*1024];
 __block NSUInteger accepted=0;
 NSInteger status=0;NSString *effective=nil;NSError *error=nil;
 NSData *limited=SFCurlFetchLimitedFinal(url,&status,&effective,&error,^BOOL(NSUInteger bytes) {
   BOOL ok=[SFHTTPBudget takeSource:bytes token:token];if(ok)accepted+=bytes;return ok;
 });
 expect(limited==nil && error!=nil,"oversized origin body aborts, never returned truncated as success");
 expect(accepted>0 && accepted<=128*1024,"upstream gate bounds retained bytes across chunks");
 expect([effective hasSuffix:@"/body"],"redirect target preserved for playlist-relative URLs");
 expect([SFHTTPBudget remaining:token]==0,"upstream exhaustion revokes further response work");
 [SFHTTPBudget close:token];accepted=0;
 limited=SFCurlFetchLimitedFinal(url,&status,NULL,NULL,^BOOL(NSUInteger bytes) {
   BOOL ok=[SFHTTPBudget takeSource:bytes token:token];if(ok)accepted+=bytes;return ok;
 });
 expect(!limited && accepted==0,"a cancelled reader cannot retain source bytes on a retry");
 NSString *stalled=[SFHTTPBudget open:1024];
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/2),dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0),^{[SFHTTPBudget close:stalled];});
 NSTimeInterval began=[NSDate timeIntervalSinceReferenceDate];
 NSData *waiting=SFCurlFetchLimitedFinal([NSString stringWithFormat:@"http://127.0.0.1:%u/stall",port],&status,NULL,NULL,^BOOL(NSUInteger bytes){return [SFHTTPBudget takeSource:bytes token:stalled];});
 expect(!waiting && [NSDate timeIntervalSinceReferenceDate]-began<3,"cancel interrupts an origin that sends no body");
 NSString *streamToken=[SFHTTPBudget open:1024];
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/2),dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0),^{[SFHTTPBudget close:streamToken];});
 began=[NSDate timeIntervalSinceReferenceDate];__block BOOL delivered=NO;
 BOOL stopped=SFCurlStreamWhile([NSString stringWithFormat:@"http://127.0.0.1:%u/stall",port],0,-1,0,
   ^BOOL{return [SFHTTPBudget takeSource:0 token:streamToken];},
   ^BOOL(NSInteger code,long long total,NSString *mime){return YES;},
   ^BOOL(NSData *bytes){delivered=YES;return YES;},NULL);
 expect(stopped && !delivered && [NSDate timeIntervalSinceReferenceDate]-began<3,"stream cancellation is polled while origin delivers no chunks");
 NSData *ordinary=SFCurlFetchFinal(url,&status,&effective,&error);
 expect(ordinary.length==body.length && status==200,"ordinary playback/download fetch remains unchanged");
 expect([SFHTTPBudget takeSource:NSUIntegerMax token:nil],"ordinary source reads need no speculative token");
 [server stop];return bad ? 1 : 0;
} }
