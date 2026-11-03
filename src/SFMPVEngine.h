// libmpv-Engine: Render-API (OpenGL) in eine CAOpenGLLayer. libmpv kommt aus dem Overlay-Port
// multimedia/mpv (ohne Cocoa/Swift, 10.9) und ist schwach gelinkt: fehlt sie, meldet
// SFMPVAvailable() NO und Sofa spielt nur über AVFoundation. Siehe SFEngine.h.
#import "SFEngine.h"

@interface SFMPVEngine : NSObject <SFEngine>
@end
