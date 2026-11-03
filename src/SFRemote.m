#import "SFRemote.h"

static CFDataRef remoteCallback(CFMessagePortRef port, SInt32 msgid, CFDataRef data, void *info) {
    SFRemote *r = (__bridge SFRemote *)info;
    if (msgid == SF_MSG_PREPARE_UPDATE) {
        if (r.updateHandler) dispatch_async(dispatch_get_main_queue(), r.updateHandler);
        return NULL;
    }
    SFKey k = (SFKey)msgid;
    if (r.handler && k >= SFKeyUp && k <= SFKeyDownHold) r.handler(k);
    return NULL;
}

@implementation SFRemote {
    CFMessagePortRef _port;
}
- (void)start {
    CFMessagePortContext ctx = {0, (__bridge void *)self, NULL, NULL, NULL};
    Boolean shouldFree = false;
    _port = CFMessagePortCreateLocal(NULL, CFSTR(SF_REMOTE_APP_PORT), remoteCallback, &ctx, &shouldFree);
    if (!_port) { SFLog(@"remote: port registration failed"); return; }
    CFRunLoopSourceRef src = CFMessagePortCreateRunLoopSource(NULL, _port, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CFRelease(src);
    SFLog(@"remote: listening on %s", SF_REMOTE_APP_PORT);
}
@end
