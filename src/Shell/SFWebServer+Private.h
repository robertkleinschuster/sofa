// Shared by SFWebServer.m (TLS, listening, dispatch, CORS) and SFWebServer+API.m (the JSON routes).
#import "SFWebServer.h"
#import "SFLocalHTTP.h"

// An answer from any queue (the exchange's calls go to its server queue)
void SFWebReply(SFHTTPExchange *x, NSInteger status, id object);

@interface SFWebServer (API)
// Main thread. `device` nil = not authenticated (only hello and pair answer then).
- (void)api:(SFHTTPExchange *)x parts:(NSArray *)parts device:(NSString *)device;
@end
