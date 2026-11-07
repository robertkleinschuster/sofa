// The mpv video layer (SFMPVEngine): libmpv's OpenGL render API drawing into a CAOpenGLLayer,
// plus dev frame grabs straight from the framebuffer.
#import <QuartzCore/QuartzCore.h>
#import <mpv/client.h>
#import <mpv/render_gl.h>
#import <OpenGL/gl3.h>

@interface SFMPVLayer : CAOpenGLLayer
@property (nonatomic) mpv_handle *mpv;
@property (nonatomic, readonly) BOOL hasRenderContext;
@property (nonatomic, copy) dispatch_block_t onRenderContext;   // called once on main when the render context exists
// Ends this layer's use of mpv and destroys the core: the main thread only detaches; freeing the
// render context and terminating mpv wait for mpv's threads and run on a background queue.
- (void)retireWithMPV:(mpv_handle *)mpv;
- (void)devFrameShot;                    // dev: save the next frame to SFMPVDevFrameShotPath
- (CGImageRef)devCopyFrameOfSize:(CGSize)size;   // dev: the current frame (+1)
+ (SFMPVLayer *)devCurrent;              // dev: most recently created layer
@end
