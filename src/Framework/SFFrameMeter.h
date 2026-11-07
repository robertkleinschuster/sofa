// SFFrameMeter - how smooth an animation really is on screen: the frames the window server
// composited while it ran, counted from a small display stream (CGDisplayStream calls back once
// per new screen frame). Sofa's animations run in the window server, outside this process, so
// neither the main thread nor a sample of Sofa sees a dropped frame (user 2026-11-07: shelf
// changes on Home did not feel like 60 fps). Off unless switched on: the stream costs the GPU a
// little scaling per frame.
#import <Foundation/Foundation.h>

void SFFrameMeterSetEnabled(BOOL on);   // main thread
BOOL SFFrameMeterEnabled(void);
// An animation of `duration` starts now: once it is over, the log says how many frames the screen
// showed meanwhile, the rate, how long the first frame took and the longest gap between frames
// and when it began ("frames: row 0.34 s - 20 frames, 59 fps, first after 12 ms, longest gap 18 ms
// at 140 ms"). No-op while off.
void SFFrameMeterMeasure(NSString *what, NSTimeInterval duration);
