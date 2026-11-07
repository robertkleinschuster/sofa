// sources: src/Apps/YouTube/SFYTPointer.m
// flags: -Isrc/Apps/YouTube -I/opt/local/include -L/opt/local/lib -lX11 -lXtst
// SFYTPointer on a real Xvfb: a window stands for the button; what the X server delivers to it is
// what a page would get - motion on the way in, then press and release of the left button inside
// the target, apart like a finger's. Skipped (exit 0) without Xvfb.
#import "SFYTPointer.h"
#include <X11/Xlib.h>
#include <signal.h>
#include <spawn.h>

BOOL SFDevMode = NO;   // main.m's, for SFCore.m
NSError *SFError(NSString *msg) { return [NSError errorWithDomain:@"Sofa" code:1 userInfo:@{NSLocalizedDescriptionKey: msg}]; }

static int fails = 0;
#define CHECK(c, msg) do { if (!(c)) { fprintf(stderr, "FAIL %s (%s:%d)\n", msg, __FILE__, __LINE__); fails++; } } while (0)

static const char *kXvfb = "/opt/local/bin/Xvfb";

// Xvfb on a free display (-displayfd); its pid, the display name in `name`.
static pid_t startXvfb(char *name, size_t len) {
    int p[2];
    if (pipe(p) != 0) return -1;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, p[1], 3);
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
    char *argv[] = {(char *)kXvfb, "-displayfd", "3", "-screen", "0", "800x600x24", "-nolisten", "tcp", NULL};
    pid_t pid = -1;
    int rc = posix_spawn(&pid, kXvfb, &fa, NULL, argv, NULL);
    posix_spawn_file_actions_destroy(&fa);
    close(p[1]);
    char buf[16] = {0};
    ssize_t n = rc == 0 ? read(p[0], buf, sizeof buf - 1) : -1;
    close(p[0]);
    if (n <= 0) { if (pid > 0) kill(pid, SIGTERM); return -1; }
    snprintf(name, len, ":%d", atoi(buf));
    return pid;
}

int main(void) {
    @autoreleasepool {
        if (access(kXvfb, X_OK) != 0) { printf("pointer skipped (no Xvfb)\n"); return 0; }
        char name[16];
        pid_t xvfb = startXvfb(name, sizeof name);
        CHECK(xvfb > 0, "Xvfb starts");
        if (xvfb <= 0) return 1;
        Display *d = XOpenDisplay(name);
        CHECK(d != NULL, "display opens");
        // the "button": a window at 300,200 120x40, far from where the pointer starts (centre)
        const CGRect target = CGRectMake(300, 200, 120, 40);
        Window w = XCreateSimpleWindow(d, DefaultRootWindow(d), 300, 200, 120, 40, 0, 0, 0);
        XSelectInput(d, w, ButtonPressMask | ButtonReleaseMask | PointerMotionMask | EnterWindowMask);
        XMapWindow(d, w);
        XSync(d, False);

        __block BOOL done = NO, ok = NO;
        [[[SFYTPointer alloc] initWithDisplay:@(name)] clickInRect:target done:^(BOOL r) { ok = r; done = YES; }];
        for (int i = 0; i < 500 && !done; i++) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        CHECK(done && ok, "the click completes");

        int motions = 0, entered = 0, presses = 0, releases = 0, pressX = -1, pressY = -1;
        Time pressedAt = 0, releasedAt = 0;
        XSync(d, False);
        while (XPending(d)) {
            XEvent e;
            XNextEvent(d, &e);
            if (e.type == MotionNotify) motions++;
            else if (e.type == EnterNotify) entered++;
            else if (e.type == ButtonPress && e.xbutton.button == Button1) { presses++; pressedAt = e.xbutton.time; pressX = e.xbutton.x; pressY = e.xbutton.y; }
            else if (e.type == ButtonRelease && e.xbutton.button == Button1) { releases++; releasedAt = e.xbutton.time; }
        }
        CHECK(entered == 1 && motions >= 1, "the pointer moves into the target (not teleported onto it)");
        CHECK(presses == 1 && releases == 1, "one press, one release of the left button");
        // well inside: the middle 60 % (window coordinates)
        CHECK(pressX >= 24 && pressX <= 96 && pressY >= 10 && pressY <= 30, "pressed well inside the target");
        CHECK(releasedAt >= pressedAt + 50, "press and release apart (>= 50 ms)");

        // a display that is not there: NO, no hang
        done = NO; ok = YES;
        [[[SFYTPointer alloc] initWithDisplay:@":999"] clickInRect:target done:^(BOOL r) { ok = r; done = YES; }];
        for (int i = 0; i < 300 && !done; i++) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        CHECK(done && !ok, "no display: done(NO)");

        XCloseDisplay(d);
        kill(xvfb, SIGTERM);
    }
    if (fails) { fprintf(stderr, "%d failure(s)\n", fails); return 1; }
    printf("pointer ok\n");
    return 0;
}
