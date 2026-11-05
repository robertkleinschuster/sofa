// Receives Apple Remote buttons from the helper (SofaRemote, LaunchAgent) via Mach port.
#import "SFCore.h"

#define SF_REMOTE_APP_PORT  "de.sofa.app.remote"     // app listens
#define SF_REMOTE_HELPER_PORT "de.sofa.helper"       // helper listens (status/ping)
#define SF_MSG_PREPARE_UPDATE 1000                   // helper -> app: save state and quit

@interface SFRemote : NSObject
@property (nonatomic, copy) void (^handler)(SFKey key);
@property (nonatomic, copy) dispatch_block_t updateHandler;   // helper: update pending
- (void)start;
@end
