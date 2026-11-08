// SFCPUMeter - what a stretch of work costs: Sofa's CPU time (all threads) over the wall time of the
// ticks that counted. The player's measure per playback (SFMPVEngine: only the seconds that played).
#import <Foundation/Foundation.h>

@interface SFCPUMeter : NSObject
// a sample: since the previous tick, CPU and wall time count when `counting` (the first tick only starts)
- (void)tick:(BOOL)counting;
@property (nonatomic, readonly) NSTimeInterval seconds;   // wall time counted
@property (nonatomic, readonly) double percentOfCore;     // CPU / wall over the counted ticks, in % of one core
@end
