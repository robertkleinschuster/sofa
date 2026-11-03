// Empfang der Apple-Remote-Tasten vom Helper (SofaRemote, LaunchAgent) per Mach-Port.
#import "SFCore.h"

#define SF_REMOTE_APP_PORT  "de.sofa.app.remote"     // App lauscht
#define SF_REMOTE_HELPER_PORT "de.sofa.helper"       // Helper lauscht (Status/Ping)
#define SF_MSG_PREPARE_UPDATE 1000                   // Helper -> App: Zustand sichern und beenden

@interface SFRemote : NSObject
@property (nonatomic, copy) void (^handler)(SFKey key);
@property (nonatomic, copy) dispatch_block_t updateHandler;   // Helper: Update steht an
- (void)start;
@end
