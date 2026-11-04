// libmpv-Engine: Render-API (OpenGL) in eine CAOpenGLLayer. libmpv kommt aus dem Overlay-Port
// multimedia/mpv (ohne Cocoa/Swift, 10.9) und ist schwach gelinkt: fehlt sie, meldet
// SFMPVAvailable() NO und Sofa spielt nur über AVFoundation. Siehe SFEngine.h.
#import "SFEngine.h"

// Dev: nächstes gerendertes mpv-Bild direkt aus dem GL-Framebuffer als PNG sichern (zeigt das
// echte Videobild, auch wenn das Dev-Fenster für den Window-Server unsichtbar ist).
extern NSString *SFMPVDevFrameShotPath;
void SFMPVDevFrameShot(NSString *path);

@interface SFMPVEngine : NSObject <SFEngine>
- (NSString *)prop:(NSString *)name;   // mpv property as text (diagnostics)
- (void)setProp:(NSString *)name value:(NSString *)value;   // dev diagnostics only
@end
