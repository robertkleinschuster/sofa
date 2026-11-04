// SFDownloads (Integrity) - downloads must never end up corrupt, whatever happens to the app.
//
// Incident 2026-11-04: the update restart ends Sofa with _exit(); the running ffmpeg survived as an
// orphan (parent = launchd) and kept writing the same .part file as the download that the new app
// instance restarted -> several writers interleaved into one 1.2 GB file full of broken NAL units.
// Layers (each one alone would have prevented or repaired it):
//   1. stopForExit: every exit path terminates the running ffmpeg first
//   2. reapOrphans: at start, ffmpeg processes of THIS instance's download root whose parent died are
//      killed (crash, SIGKILL, older versions) - dev and real instance have different roots
//   3. part files are unique per app process and stale ones are swept at start
//   4. every finished file is verified (duration + decode probes) before it replaces the target
//   5. a one-time audit verifies existing downloads and re-queues broken ones
#import "SFDownloads+Private.h"
#import <sys/sysctl.h>
#import <signal.h>

static NSString *const kAuditKey = @"downloadsAuditVersion";
static NSString *const kAuditVersion = @"1";

@implementation SFDownloads (Integrity)

#pragma mark Orphans and stale parts

// argv of a process (KERN_PROCARGS2: argc, exec path, padding, argv...), nil if not readable
static NSArray *SFProcessArgs(pid_t pid) {
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t size = 0;
    int maxArg = 0; size_t ml = sizeof(maxArg);
    int am[2] = {CTL_KERN, KERN_ARGMAX};
    if (sysctl(am, 2, &maxArg, &ml, NULL, 0) != 0) return nil;
    size = (size_t)maxArg;
    char *buf = malloc(size);
    if (!buf) return nil;
    if (sysctl(mib, 3, buf, &size, NULL, 0) != 0 || size < sizeof(int)) { free(buf); return nil; }
    int argc; memcpy(&argc, buf, sizeof(argc));
    char *p = buf + sizeof(int), *end = buf + size;
    while (p < end && *p) p++;            // exec path
    while (p < end && !*p) p++;           // padding
    NSMutableArray *args = [NSMutableArray array];
    for (int i = 0; i < argc && p < end; i++) {
        NSString *s = [NSString stringWithUTF8String:p];
        [args addObject:s ?: @""];
        p += strlen(p) + 1;
    }
    free(buf);
    return args;
}

- (NSUInteger)reapOrphans {
    NSString *root = [[SFDownloads root] stringByAppendingString:@"/"];
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_UID, (int)getuid()};
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || !size) return 0;
    struct kinfo_proc *procs = malloc(size);
    if (!procs || sysctl(mib, 4, procs, &size, NULL, 0) != 0) { free(procs); return 0; }
    NSUInteger n = size / sizeof(struct kinfo_proc), reaped = 0;
    NSMutableArray *victims = [NSMutableArray array];
    pid_t own = _task.isRunning ? _task.processIdentifier : 0;
    for (NSUInteger i = 0; i < n; i++) {
        struct kinfo_proc *kp = &procs[i];
        pid_t pid = kp->kp_proc.p_pid;
        if (pid == own || kp->kp_eproc.e_ppid != 1) continue;               // only orphans
        if (strcmp(kp->kp_proc.p_comm, "ffmpeg") != 0) continue;
        NSArray *args = SFProcessArgs(pid);
        BOOL ours = NO;
        for (NSString *a in args) if ([a hasPrefix:root]) { ours = YES; break; }   // writes into our root
        if (!ours) continue;
        SFLog(@"downloads: killing orphaned ffmpeg %d (left over from an earlier run): %@", pid, [(NSString *)args.lastObject lastPathComponent]);
        kill(pid, SIGTERM);
        reaped++;
        [victims addObject:@(pid)];
    }
    free(procs);
    // ffmpeg only honours SIGTERM between packets; one stuck in a dead network read ignores it
    // (seen 2026-11-04) -> escalate to SIGKILL after a short grace period
    for (int i = 0; i < 20 && victims.count; i++) {
        usleep(50 * 1000);
        for (NSNumber *v in [victims copy]) if (kill(v.intValue, 0) != 0) [victims removeObject:v];
    }
    for (NSNumber *v in victims) { SFLog(@"downloads: ffmpeg %@ ignored SIGTERM - SIGKILL", v); kill(v.intValue, SIGKILL); }
    if (reaped) usleep(100 * 1000);
    return reaped;
}

- (void)sweepStaleParts {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [SFDownloads root];
    NSString *mine = [self partSuffix];
    NSUInteger n = 0;
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
    for (NSString *rel in en) {
        if ([rel rangeOfString:@".part"].location == NSNotFound || ![rel hasSuffix:@".mp4"]) continue;
        if ([rel hasSuffix:mine]) continue;
        if ([fm removeItemAtPath:[root stringByAppendingPathComponent:rel] error:nil]) n++;
    }
    if (n) SFLog(@"downloads: removed %lu stale partial file(s)", (unsigned long)n);
}

// Part files are unique per app process: an orphan of an earlier run can never share a file with us.
- (NSString *)partSuffix { return [NSString stringWithFormat:@".part%d.mp4", getpid()]; }

#pragma mark Verification

// Runs ffmpeg synchronously (call off the main thread); returns stderr.
static NSString *SFRunFF(NSString *ff, NSArray *args) {
    NSTask *t = [NSTask new];
    t.launchPath = @"/usr/bin/nice";
    t.arguments = [@[@"-n", @"15", ff, @"-nostdin", @"-hide_banner"] arrayByAddingObjectsFromArray:args];
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
    t.environment = env;
    NSPipe *err = [NSPipe pipe];
    t.standardError = err; t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    t.standardInput = [NSFileHandle fileHandleWithNullDevice];
    @try { [t launch]; } @catch (NSException *e) { return nil; }
    NSData *d = [err.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
}

static double SFParseDuration(NSString *s) {
    NSRange r = [s rangeOfString:@"Duration: "];
    if (r.location == NSNotFound) return 0;
    NSArray *p = [[s substringWithRange:NSMakeRange(NSMaxRange(r), MIN(11, s.length - NSMaxRange(r)))] componentsSeparatedByString:@":"];
    if (p.count != 3) return 0;
    return [p[0] doubleValue] * 3600 + [p[1] doubleValue] * 60 + [p[2] doubleValue];
}

// nil = file is fine, otherwise a short English reason. Synchronous, call off the main thread.
+ (NSString *)problemWithFile:(NSString *)path expectedDuration:(double)expected ffmpeg:(NSString *)ff {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return @"file missing";
    NSString *info = SFRunFF(ff, @[@"-i", path]);
    if (!info) return nil;   // cannot check -> do not destroy anything
    double dur = SFParseDuration(info);
    if (dur <= 0) return @"no duration (unreadable container)";
    if (expected > 60 && fabs(dur - expected) > MAX(20, expected * 0.03))
        return [NSString stringWithFormat:@"duration %.0f s, expected %.0f s", dur, expected];
    unsigned long long bytes = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
    if (dur > 0 && bytes * 8 / dur > 60e6) return [NSString stringWithFormat:@"implausible bitrate %.0f Mbit/s", bytes * 8 / dur / 1e6];
    // decode probes at start, middle and end: a healthy file decodes without errors
    for (NSNumber *f in @[@0.02, @0.5, @0.95]) {
        double at = MAX(0, dur * f.doubleValue - 2);
        NSString *e = SFRunFF(ff, @[@"-v", @"error", @"-ss", [NSString stringWithFormat:@"%.1f", at], @"-t", @"3",
                                    @"-i", path, @"-map", @"0:v:0?", @"-map", @"0:a:0?", @"-f", @"null", @"-"]);
        NSUInteger lines = 0;
        for (NSString *l in [e componentsSeparatedByString:@"\n"]) if (l.length) lines++;
        if (lines > 3) return [NSString stringWithFormat:@"%lu decode errors at %.0f s", (unsigned long)lines, at];
    }
    return nil;
}

#pragma mark Audit of existing downloads

- (void)auditExistingDownloads {
    if ([[[SFStore shared] setting:kAuditKey] isEqualToString:kAuditVersion]) return;
    NSString *ff = [SFDownloads ffmpegToolPath];
    if (!ff) return;
    NSMutableArray *todo = [NSMutableArray array];
    for (NSDictionary *r in _recs.allValues)
        if ([r[@"state"] integerValue] == SFDLDone && [r[@"path"] length]) [todo addObject:r[@"id"]];
    SFLog(@"downloads: verifying %lu existing download(s) once in the background", (unsigned long)todo.count);
    [self auditNext:todo ff:ff broken:0];
}

- (void)auditNext:(NSMutableArray *)todo ff:(NSString *)ff broken:(NSUInteger)broken {
    if (!todo.count) {
        SFLog(@"downloads: verification finished, %lu broken file(s) re-queued", (unsigned long)broken);
        [[SFStore shared] setSetting:kAuditVersion forKey:kAuditKey];
        return;
    }
    NSString *ident = todo.lastObject; [todo removeLastObject];
    NSDictionary *r = _recs[ident];
    NSString *path = r[@"path"];
    if ([r[@"state"] integerValue] != SFDLDone || !path || [ident isEqualToString:_runningID]) { [self auditNext:todo ff:ff broken:broken]; return; }
    double expected = [self itemFromRec:r].duration;
    SFBackground(^{
        NSString *problem = [SFDownloads problemWithFile:path expectedDuration:expected ffmpeg:ff];
        SFMain(^{
            NSUInteger b = broken;
            NSMutableDictionary *rr = self->_recs[ident];
            if (problem && rr && [rr[@"path"] isEqualToString:path] && [rr[@"state"] integerValue] == SFDLDone) {
                // Keep the old file until a verified replacement exists: the verifier could be wrong, and
                // Mediathek items may have expired upstream (finish:ok:NO then keeps the old file).
                SFLog(@"downloads: %@ is broken (%@) - downloading it again", ident, problem);
                [rr removeObjectForKey:@"error"];
                rr[@"state"] = @(SFDLQueued); rr[@"progress"] = @0; rr[@"tries"] = @0;
                [self save:rr]; [self changed:ident];
                b++;
                [self pump];
            }
            // pace the audit: low priority, one file every few seconds
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self auditNext:todo ff:ff broken:b];
            });
        });
    });
}

@end
