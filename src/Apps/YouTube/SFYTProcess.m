#import "SFYTProcess.h"
#import "SFCore.h"
#include <spawn.h>
#include <signal.h>
#include <libproc.h>
#include <sys/wait.h>

// The environment of Sofa minus what must not reach the browser, plus `extra`.
static char **Environment(NSDictionary *extra) {
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    for (NSString *k in @[@"DYLD_INSERT_LIBRARIES", @"MOZ_HEADLESS", @"DISPLAY"]) [env removeObjectForKey:k];
    [env addEntriesFromDictionary:extra];
    char **e = calloc(env.count + 1, sizeof(char *));
    __block size_t i = 0;
    [env enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) { e[i++] = strdup([NSString stringWithFormat:@"%@=%@", k, v].UTF8String); }];
    return e;
}

static void FreeStrings(char **a) { for (char **p = a; *p; p++) free(*p); free(a); }

pid_t SFYTSpawn(NSString *path, NSArray *args, NSDictionary *env, int in, int log, int fd3) {
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    if (in >= 0) posix_spawn_file_actions_adddup2(&fa, in, 0);
    else posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&fa, log, 1);
    posix_spawn_file_actions_adddup2(&fa, log, 2);
    if (fd3 >= 0) posix_spawn_file_actions_adddup2(&fa, fd3, 3);
    posix_spawnattr_t at;
    posix_spawnattr_init(&at);
    // nothing else inherited, an own process group, and signals as a fresh process has them: the
    // caller is a GCD thread with most signals blocked, and a child inheriting that mask ignored
    // SIGTERM (measured 2026-11-07: Firefox and Xvfb outlived every stop)
    posix_spawnattr_setflags(&at, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
    posix_spawnattr_setpgroup(&at, 0);
    sigset_t none, all;
    sigemptyset(&none); sigfillset(&all);
    posix_spawnattr_setsigmask(&at, &none);
    posix_spawnattr_setsigdefault(&at, &all);
    char **argv = calloc(args.count + 2, sizeof(char *));
    argv[0] = strdup(path.UTF8String);
    for (NSUInteger i = 0; i < args.count; i++) argv[i + 1] = strdup([args[i] UTF8String]);
    char **envp = Environment(env);
    pid_t pid = 0;
    int rc = posix_spawn(&pid, path.UTF8String, &fa, &at, argv, envp);
    FreeStrings(argv); FreeStrings(envp);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&at);
    if (rc != 0) { SFLog(@"yt-browser: cannot start %@: %s", path.lastPathComponent, strerror(rc)); return 0; }
    return pid;
}

BOOL SFYTProcessIs(pid_t pid, NSString *name) {
    if (pid <= 0) return NO;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, path, sizeof path) <= 0) return NO;   // gone
    return [[@(path) lastPathComponent] isEqualToString:name];
}

void SFYTEndProcess(pid_t pid, NSString *name) {
    if (!SFYTProcessIs(pid, name)) return;   // gone, or the pid was reused by another program
    kill(pid, SIGTERM);
    // waitpid reaps our own children; an adopted process (an earlier Sofa's) is launchd's
    for (int i = 0; i < 50 && kill(pid, 0) == 0; i++) {
        if (waitpid(pid, NULL, WNOHANG) == pid) return;
        usleep(100000);
    }
    if (kill(pid, 0) == 0) { kill(pid, SIGKILL); waitpid(pid, NULL, WNOHANG); }
}

// $0: grace seconds, then "pid:name" per process. `ps -o comm=` is the executable's path: a pid
// that meanwhile runs another program is left alone.
static NSString *const kWatcherScript =
    @"read _; [ \"$0\" -gt 0 ] && sleep \"$0\"; "
    @"for x in \"$@\"; do p=${x%%:*}; n=${x#*:}; "
    @"case \"$(ps -o comm= -p \"$p\" 2>/dev/null)\" in \"$n\"|*/\"$n\") kill \"$p\" 2>/dev/null;; esac; done";

@implementation SFYTWatcher {
    int _lifeline;   // Sofa's end of the pipe; -1 once closed
}

- (instancetype)init {
    if ((self = [super init])) _lifeline = -1;
    return self;
}

+ (instancetype)watch:(NSDictionary *)processes grace:(int)grace log:(int)log {
    int p[2];
    if (pipe(p) != 0) return nil;
    fcntl(p[1], F_SETFD, FD_CLOEXEC);   // no other child of Sofa keeps the pipe open
    NSMutableArray *args = [NSMutableArray arrayWithObjects:@"-c", kWatcherScript, @(MAX(0, grace)).stringValue, nil];
    [processes enumerateKeysAndObjectsUsingBlock:^(NSNumber *pid, NSString *name, BOOL *stop) {
        [args addObject:[NSString stringWithFormat:@"%d:%@", pid.intValue, name]];
    }];
    pid_t w = SFYTSpawn(@"/bin/sh", args, @{}, p[0], log, -1);
    close(p[0]);
    if (w <= 0) { close(p[1]); return nil; }
    SFYTWatcher *s = [SFYTWatcher new];
    s->_pid = w;
    s->_lifeline = p[1];
    return s;
}

// The shell and its sleep: SFYTSpawn made the shell a process group leader.
static void EndGroup(pid_t w) {
    if (SFYTProcessIs(w, @"sh")) killpg(w, SIGKILL);
}

- (void)closeLifeline {
    if (_lifeline >= 0) close(_lifeline);
    _lifeline = -1;
}

- (void)cancel {
    pid_t w = _pid;
    _pid = 0;
    if (w > 0) EndGroup(w);   // before the lifeline closes: nothing gets to run the kill
    [self closeLifeline];
    if (w > 0) dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{ waitpid(w, NULL, 0); });
}

+ (void)endEarlier:(pid_t)pid { if (pid > 0) EndGroup(pid); }

- (void)dealloc { [self closeLifeline]; }
@end
