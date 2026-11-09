// sources: src/Library/SFPrebufferReader.m src/Core/SFHTTPBudget.m src/Core/SFLocalHTTP.m src/Core/SFWebSocket.m
// flags: -Isrc/Library -I/opt/local/include -L/opt/local/lib -lmpv
#import "SFPrebufferReader.h"
#import "SFLocalHTTP.h"
BOOL SFDevMode=NO;
int main(void) { @autoreleasepool {
 SFLocalHTTP *s=[[SFLocalHTTP alloc] initWithName:@"prebuffer-cancel-test" queue:dispatch_queue_create("prebuffer-cancel-test",DISPATCH_QUEUE_SERIAL) maxBody:0 handler:^(SFHTTPExchange *x) {
   x.onClose=^{ (void)x; }; // explicit ownership until reader cancellation closes the socket
   [x begin:200 headers:@{@"Content-Length":@"2097152",@"Content-Type":@"video/mp4"}];
 }];
 if(![s startPreferringPort:0])return 1;
 SFPrebufferRead *request=[SFPrebufferRead new];
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/2),dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0),^{request.cancelled=YES;});
 NSTimeInterval start=[NSDate timeIntervalSinceReferenceDate];
 NSDictionary *result=[SFPrebufferReader readURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/stalled.mp4",s.port]] audio:nil position:30 request:request];
 double elapsed=[NSDate timeIntervalSinceReferenceDate]-start;
 [s stop];
 BOOL ok=[result[@"reason"] isEqual:@"cancelled"] && elapsed<3;
 printf("%s reader cancelled during stalled media open in %.3f s\n",ok ? "ok" : "FAIL",elapsed);
 return ok ? 0 : 1;
} }
