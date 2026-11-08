#import "SFCPUMeter.h"
#import <sys/resource.h>

// Sofa's CPU time so far (user + system, all threads), seconds
static double ProcessCPU(void) {
    struct rusage u;
    if (getrusage(RUSAGE_SELF, &u) != 0) return 0;
    return u.ru_utime.tv_sec + u.ru_utime.tv_usec / 1e6 + u.ru_stime.tv_sec + u.ru_stime.tv_usec / 1e6;
}

@implementation SFCPUMeter {
    double _cpuLast, _wallLast, _cpu, _wall;
}

- (void)tick:(BOOL)counting {
    double cpu = ProcessCPU(), wall = [NSDate timeIntervalSinceReferenceDate];
    if (_wallLast > 0 && counting) { _cpu += cpu - _cpuLast; _wall += wall - _wallLast; }
    _cpuLast = cpu; _wallLast = wall;
}

- (NSTimeInterval)seconds { return _wall; }
- (double)percentOfCore { return _wall > 0 ? 100 * _cpu / _wall : 0; }

@end
