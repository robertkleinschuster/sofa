// libmpv engine: render API (OpenGL) into a CAOpenGLLayer. libmpv comes from the overlay port
// multimedia/mpv (without Cocoa/Swift, 10.9). See SFEngine.h.
#import "SFEngine.h"

// Dev: save the next rendered mpv frame straight from the GL framebuffer as PNG (shows the
// real video frame even when the dev window is invisible to the window server).
extern NSString *SFMPVDevFrameShotPath;
void SFMPVDevFrameShot(NSString *path);

@interface SFMPVEngine : NSObject <SFEngine>
- (NSString *)prop:(NSString *)name;   // mpv property as text (diagnostics)
- (void)setProp:(NSString *)name value:(NSString *)value;   // dev diagnostics only
@end
