// sofa-fand - always-on fan control, portable across Intel Macs whose SMC takes forced fan targets.
//
// Emulates "fan minimum = 0" with its own curves: cool -> fans down to 0 rpm, warm -> more speed
// than Apple's SMC would run. The daemon drives the fans in the SMC's forced mode (FS! + F<n>Tg); the
// SMC regulates again (FS! = 0) on every fault: unreadable sensor, SMC error, a fan that does not
// turn, crash, SIGKILL, hang, stop. A temperature limit forces every fan to its maximum instead.
//
// Processes: launchd starts the guard; it resets FS! = 0, discovers the machine, reads the
// configuration, binds the sockets and forks the controller. If the controller dies (even SIGKILL)
// or stops beating, the guard resets FS! = 0 at once and forks a new one - no exec, no disk. On
// SIGHUP the guard reads the configuration again and hands it to the running controller (shared
// page): a reload never gives the fans back to the SMC in between.
//
//   sofa-fand run [-c CONF] [-l LEARNED] [-n]   daemon (launchd, root); -n: dry run
//   sofa-fand status | state                    state, fans, temperatures, recent log
//   sofa-fand hint CTX [VOL] [TTL]              send a context hint like Sofa does (testing)
//   sofa-fand hw                                what this Mac has (fans, temperature keys, Apple limits)
//   sofa-fand check [-c CONF] [-l LEARNED]      parse + validate, print the effective configuration
//   sofa-fand apply FILE                        validate FILE as the learned layer, install it, reload (root)
//   sofa-fand rollback                          back to the previous learned layer (or none), reload (root)
//   sofa-fand reload                            read the files again (root)
//   sofa-fand reset                             FS! = 0 directly through the SMC (root, no daemon needed)
//   sofa-fand learn [-n]                        nightly learner (learn.c): judge, model, step, identification (root)
//   sofa-fand init [-o FILE]                    an Apple-equivalent reference for this Mac
//   sofa-fand migrate [LOGDIR]                  the old collector's data into the recorder's directory (root, once)
//   sofa-fand ident SECS TAG RPM... | identstop  an identification step through the daemon (root, Sofa resting)
#include "fand.h"
#include "learn.h"
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <syslog.h>
#include <unistd.h>

#define GUARD_PID   (dry ? "/var/run/sofa-fand-dry/guard.pid" : "/var/run/sofa-fand/guard.pid")

// ============================================================================ process glue
static void ctl_crash(int sig) {
  // async-signal-safe enough: two IOConnectCallStructMethod calls (Mach messages), then _exit
  fs_set(0); fs_set(0);
  _exit(128 + sig);
}
static volatile sig_atomic_t ctl_stop;
static void ctl_term(int sig) { (void)sig; ctl_stop = 1; poke(wake_pipe[1]); }

static unsigned long lock_memory(void) {
  // Wire only this program's own segments. Wiring every loaded system image (shared cache) and
  // mlockall coincided on 2026-11-17 22:19 with a system-wide crash wave ("DYLD shared region
  // unnest"): never on 10.9.
  unsigned long kb = 0;
  const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(0);
  if (!mh || mh->magic != MH_MAGIC_64) return 0;
  intptr_t slide = _dyld_get_image_vmaddr_slide(0);
  const struct load_command *lc = (const struct load_command *)(mh + 1);
  for (uint32_t j = 0; j < mh->ncmds; j++, lc = (const struct load_command *)((const char *)lc + lc->cmdsize)) {
    if (lc->cmd != LC_SEGMENT_64) continue;
    const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
    if (!strcmp(sg->segname, "__PAGEZERO") || !strcmp(sg->segname, "__LINKEDIT") || !sg->vmsize) continue;
    if (mlock((void *)(uintptr_t)(sg->vmaddr + (uint64_t)slide), (size_t)sg->vmsize) == 0) kb += (unsigned long)(sg->vmsize / 1024);
  }
  return kb;
}

static void ctl_atexit(void) { smc_auto(); }

static void prefault_stack(void) {
  // touch and wire 256 KB of this thread's stack below the current frame
  volatile char buf[256 * 1024];
  for (size_t i = 0; i < sizeof buf; i += 4096) buf[i] = 0;
  mlock((const void *)buf, sizeof buf);
}

static int spawn(void *(*fn)(void *)) {
  // own stack, wired, so a vanished swap/boot disk cannot stall a helper thread on a page-in
  size_t sz = 512 * 1024;
  void *stk = mmap(NULL, sz, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
  pthread_attr_t a; pthread_t th; int r;
  if (stk == MAP_FAILED) return -1;
  memset(stk, 0, sz); mlock(stk, sz);
  pthread_attr_init(&a); pthread_attr_setstack(&a, stk, sz); pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
  r = pthread_create(&th, &a, fn, NULL);
  pthread_attr_destroy(&a);
  return r;
}

// a reload the guard published: copy it out consistently (seqlock) and take it
static unsigned cfg_seen;
static void take_reload(void) {
  static cfg_t staged;              // static: far too large for a wired stack frame
  unsigned g = shcfg->gen;
  if (g == cfg_seen || (g & 1)) return;
  __sync_synchronize();
  memcpy(&staged, (const void *)&shcfg->cfg, sizeof staged);
  __sync_synchronize();
  if (shcfg->gen != g) return;      // written meanwhile: next round
  cfg_seen = g;
  control_take_cfg(&staged);
  record_request_flush();          // rows of the old configuration go to disk under their header
}

static void controller(void) {
  pid_t guard = getppid();
  static char altstack[64 * 1024];
  stack_t ss = { .ss_sp = altstack, .ss_size = sizeof altstack, .ss_flags = 0 };
  sigaltstack(&ss, NULL);                                          // crash handler works on stack overflow
  struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = ctl_crash; sa.sa_flags = SA_ONSTACK;
  sigaction(SIGSEGV, &sa, NULL); sigaction(SIGBUS, &sa, NULL); sigaction(SIGILL, &sa, NULL); sigaction(SIGFPE, &sa, NULL); sigaction(SIGABRT, &sa, NULL);
  signal(SIGTERM, ctl_term); signal(SIGINT, ctl_term); signal(SIGHUP, SIG_IGN); signal(SIGPIPE, SIG_IGN);
  if (smc_open()) { syslog(LOG_ERR, "controller: AppleSMC not reachable"); _exit(1); }
  smc_auto();
  atexit(ctl_atexit);
  cfg_seen = shcfg->gen;            // the configuration forked with is the current one
  control_init(now_s());
  { char b[64]; while (read(wake_pipe[0], b, sizeof b) > 0) {} while (read(push_pipe[0], b, sizeof b) > 0) {} }   // a predecessor's
  log_start_threaded();
  if (spawn(log_thread)) syslog(LOG_ERR, "no log thread");
  if (spawn(smart_thread)) syslog(LOG_ERR, "no SMART thread");
  if (spawn(socket_thread)) syslog(LOG_ERR, "no socket thread");
  if (spawn(load_thread)) syslog(LOG_ERR, "no load thread");
  if (spawn(power_thread)) syslog(LOG_ERR, "no power thread");
  if (spawn(record_thread)) syslog(LOG_ERR, "no recorder thread");
  control_set_locked_kb(lock_memory());
  prefault_stack();
  logf_("controller up (pid %d, %s, %d fans, %lu KB wired)%s%s%s", getpid(), machine.model, control_fan_count(), control_locked_kb(),
        cfg.ok ? "" : ", DISABLED: ", cfg.ok ? "" : cfg.err, cfg.learned < 0 ? ", learned layer REFUSED" : cfg.learned > 0 ? ", learned layer in effect" : "");
  if (cfg.learned < 0) logf_("learned layer refused: %s", cfg.err_learned);
  double next = now_s();
  while (!ctl_stop) {
    if (getppid() != guard) { logf_("guard gone - stopping, FS!=0"); break; }   // launchd starts a new guard
    take_reload();
    double t = now_s();
    if (t >= next) { control_step(); shm->beat = now_s(); next = t + control_next_dt(); shm->beat_due = next + 5; }
    double wait = next - now_s();
    if (wait > 0) {
      // one sleep until the next step; a signal, a new hint or a reload wakes it early (no polling)
      struct pollfd pf = { wake_pipe[0], POLLIN, 0 };
      if (poll(&pf, 1, (int)(wait * 1000) + 1) > 0) { char b[16]; while (read(wake_pipe[0], b, sizeof b) > 0) {} if (!ctl_stop) next = now_s(); }
    }
  }
  smc_auto(); shm->forced = 0;
  if (!dry) record_flush();         // the fans are the SMC's already: now the disk may take its time
  logf_("controller stopped, FS!=0");
  usleep(200000);
  _exit(0);
}

// ================================================================================= guard
static volatile sig_atomic_t guard_stop, guard_reload;
static void guard_term(int sig) { (void)sig; guard_stop = 1; }
static void guard_hup(int sig) { (void)sig; guard_reload = 1; }

static int bind_sock(const char *path, int type, mode_t mode) {
  int fd = socket(AF_UNIX, type, 0);
  if (fd < 0) return -1;
  struct sockaddr_un sa; memset(&sa, 0, sizeof sa); sa.sun_family = AF_UNIX;
  snprintf(sa.sun_path, sizeof sa.sun_path, "%s", path);
  unlink(path);
  if (bind(fd, (struct sockaddr *)&sa, sizeof sa) || (type == SOCK_STREAM && listen(fd, 8)) || chmod(path, mode)) { close(fd); return -1; }
  int fl = fcntl(fd, F_GETFL); if (fl >= 0) fcntl(fd, F_SETFL, fl | O_NONBLOCK);
  fcntl(fd, F_SETFD, FD_CLOEXEC);
  int big = 64 * 1024; setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &big, sizeof big);
  return fd;
}

// The learned layer is read only from a root-owned file nobody else may write (it came through
// `apply`, which validated it); anything else is ignored and named in the log.
static const char *learned_source(const char *path, char *why, size_t cap) {
  struct stat sd, sf;
  why[0] = 0;
  if (lstat(path, &sf) && errno == ENOENT) return path;              // no layer: fine
  char dir[256]; snprintf(dir, sizeof dir, "%s", path); char *sl = strrchr(dir, '/'); if (sl) *sl = 0;
  if (lstat(dir, &sd) || !S_ISDIR(sd.st_mode) || sd.st_uid != 0 || (sd.st_mode & 022)) { snprintf(why, cap, "%s is not a root-only directory", dir); return NULL; }
  if (lstat(path, &sf) || !S_ISREG(sf.st_mode) || sf.st_uid != 0 || (sf.st_mode & 022)) { snprintf(why, cap, "%s is not a root-only file", path); return NULL; }
  return path;
}

static void load_into(cfg_t *c, const char *conf, const char *learned) {
  char why[200]; const char *src = learned_source(learned, why, sizeof why);
  cfg_load(c, conf, src, &machine);
  if (!src && c->ok) { c->learned = -1; snprintf(c->err_learned, sizeof c->err_learned, "%s", why); }
}

static int run_daemon(const char *conf, const char *learned) {
  openlog("sofa-fand", LOG_PID, LOG_DAEMON);
  // 1. safety first: whatever a previous instance left behind, the SMC regulates again
  if (smc_open()) { syslog(LOG_ERR, "AppleSMC not reachable"); return 1; }
  int first = smc_auto();
  // 2. the machine (fan limits are what smc_auto forces should FS! ever refuse to clear)
  if (machine_discover(&machine)) syslog(LOG_ERR, "machine: %s - fans stay under SMC control", machine.err);
  for (int n = 0; n < machine.nfans; n++) smc_set_fan_max(n, machine.fan[n].max);
  if (first && smc_auto()) syslog(LOG_ERR, "FS! reset failed at start");
  // 3. configuration (again on SIGHUP)
  load_into(&cfg, conf, learned);
  if (!cfg.ok) syslog(LOG_ERR, "config: %s - fans stay under SMC control", cfg.err);
  else if (cfg.learned < 0) syslog(LOG_ERR, "learned layer refused: %s - reference only", cfg.err_learned);
  // 4. sockets (bound by the guard, inherited by every controller)
  struct stat sd;
  if (lstat(RUN_DIR, &sd) == 0 && (!S_ISDIR(sd.st_mode) || sd.st_uid != 0)) { syslog(LOG_ERR, "%s is not a root directory, refusing", RUN_DIR); return 1; }
  if (mkdir(RUN_DIR, 0755) && errno != EEXIST) { syslog(LOG_ERR, "mkdir %s: %m", RUN_DIR); return 1; }
  chmod(RUN_DIR, 0755);
  if (!dry) unlink("/var/run/sofa-fand.sock");                       // v1 leftover
  lfd_hint = bind_sock(HINT_SOCK, SOCK_DGRAM, 0666);
  lfd_ctl = bind_sock(CTL_SOCK, SOCK_STREAM, 0666);
  if (lfd_hint < 0 || lfd_ctl < 0) syslog(LOG_ERR, "sockets unavailable: %m - no hints, no status (fans still regulated)");
  shm = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
  shcfg = mmap(NULL, sizeof(shcfg_t), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
  if (shm == MAP_FAILED || shcfg == MAP_FAILED) { syslog(LOG_ERR, "mmap failed"); return 1; }
  mlock(shm, 4096); mlock(shcfg, sizeof(shcfg_t));
  // created here and inherited by every controller: the guard wakes a controller after a reload
  if (pipe(wake_pipe) || pipe(push_pipe)) { syslog(LOG_ERR, "pipe failed"); return 1; }
  for (int i = 0; i < 2; i++) { fcntl(wake_pipe[i], F_SETFL, O_NONBLOCK); fcntl(push_pipe[i], F_SETFL, O_NONBLOCK); fcntl(wake_pipe[i], F_SETFD, FD_CLOEXEC); fcntl(push_pipe[i], F_SETFD, FD_CLOEXEC); }
  FILE *pf = fopen(GUARD_PID, "w"); if (pf) { fprintf(pf, "%d\n", getpid()); fclose(pf); }
  signal(SIGTERM, guard_term); signal(SIGINT, guard_term); signal(SIGPIPE, SIG_IGN);
  struct sigaction hs; memset(&hs, 0, sizeof hs); hs.sa_handler = guard_hup; sigaction(SIGHUP, &hs, NULL);   // no SA_RESTART: wakes the kevent wait
  unsigned long kb = lock_memory(); (void)kb;
  prefault_stack();
  syslog(LOG_NOTICE, "guard up (pid %d, %s, %d fans)%s", getpid(), machine.model, machine.nfans, dry ? " DRY RUN" : "");
  int restarts = 0; double window = now_s();
  while (!guard_stop) {
    shm->beat = now_s(); shm->forced = 0; shm->beat_due = now_s() + 30;   // start-up grace
    pid_t child = fork();
    if (child == 0) controller();
    if (child < 0) { smc_auto(); sleep(5); continue; }
    // the kernel tells us at once when the controller exits (kqueue NOTE_EXIT); otherwise the
    // guard wakes every 5 s for the heartbeat check (or at once on SIGHUP)
    int kq = kqueue();
    struct kevent ke; EV_SET(&ke, child, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    if (kq >= 0 && kevent(kq, &ke, 1, NULL, 0, NULL) < 0) { close(kq); kq = -1; }
    while (!guard_stop) {
      if (guard_reload) {
        guard_reload = 0;
        static cfg_t next;                                        // the guard may touch the disk
        load_into(&next, conf, learned);
        if (!next.ok) guard_log("reload: %s - keeping the running configuration", next.err);
        else {
          cfg = next;                                             // for every later controller
          shcfg->gen++; __sync_synchronize();                     // odd: being written
          memcpy((void *)&shcfg->cfg, &next, sizeof next);
          __sync_synchronize(); shcfg->gen++;                     // even: complete
          poke(wake_pipe[1]);                                     // the controller takes it at once
        }
      }
      int stv = 0; pid_t r = waitpid(child, &stv, WNOHANG);
      if (r == child || (r < 0 && errno == ECHILD)) {
        int failed = smc_auto();                         // controller gone: SMC first, then talk
        guard_log("controller %d ended (%s %d), FS!=0%s", child, WIFSIGNALED(stv) ? "signal" : "exit",
               WIFSIGNALED(stv) ? WTERMSIG(stv) : WEXITSTATUS(stv), failed ? " FAILED" : "");
        break;
      }
      // hang: the controller missed its own announced next beat by 10 s, or, as a hard cap, no
      // beat at all for GUARD_STALE
      if (now_s() > shm->beat_due + 10 || now_s() - shm->beat > GUARD_STALE) {
        smc_auto(); kill(child, SIGKILL); waitpid(child, &stv, 0); smc_auto();
        guard_log("controller %d hung (last beat %.0f s ago, %.0f s past its announced next step), killed, FS!=0", child, now_s() - shm->beat, now_s() - shm->beat_due);
        break;
      }
      // belt and braces: FS! set while the controller says it forces nothing
      if (!dry && shm->forced == 0 && fs_get() > 0) { usleep(300000); if (shm->forced == 0 && fs_get() > 0) { smc_auto(); guard_log("FS! set without controller request, reset"); } }
      if (kq >= 0) { struct kevent ev; struct timespec to = { 5, 0 }; kevent(kq, NULL, 0, &ev, 1, &to); }   // exit event, SIGHUP or 5 s
      else usleep(500000);
    }
    if (kq >= 0) close(kq);
    if (guard_stop) {
      kill(child, SIGTERM);
      for (int i = 0; i < 20 && waitpid(child, NULL, WNOHANG) == 0; i++) usleep(100000);
      kill(child, SIGKILL); waitpid(child, NULL, 0);
      break;
    }
    if (now_s() - window > 300) { window = now_s(); restarts = 0; }
    if (++restarts > 5) { guard_log("controller keeps failing, pausing 60 s (fans: SMC)"); smc_auto(); for (int i = 0; i < 60 && !guard_stop; i++) sleep(1); restarts = 0; }
    else sleep(2);
  }
  smc_auto();
  unlink(HINT_SOCK); unlink(CTL_SOCK); unlink(GUARD_PID);
  syslog(LOG_NOTICE, "guard stopped, FS!=0 (0x%x)", fs_get());
  return 0;
}

// ================================================================================ client
static int ctl_client(const char *cmd, char *capture, size_t cap) {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return 1;
  struct sockaddr_un sa; memset(&sa, 0, sizeof sa); sa.sun_family = AF_UNIX;
  snprintf(sa.sun_path, sizeof sa.sun_path, "%s", CTL_SOCK);
  struct timeval tv = { 3, 0 };
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  if (connect(fd, (struct sockaddr *)&sa, sizeof sa)) { if (!capture) fprintf(stderr, "sofa-fand not reachable (%s)\n", CTL_SOCK); close(fd); return 1; }
  char line[600]; int n = snprintf(line, sizeof line, "%s\n", cmd);
  if (n <= 0 || n >= (int)sizeof line || write(fd, line, (size_t)n) != n) { close(fd); return 1; }
  char buf[4096]; ssize_t r; int err = 0; size_t o = 0;
  while ((r = read(fd, buf, sizeof buf)) > 0) {
    if (!strncmp(buf, "ERR", 3)) err = 1;
    if (capture) { size_t k = (size_t)r < cap - 1 - o ? (size_t)r : cap - 1 - o; memcpy(capture + o, buf, k); o += k; capture[o] = 0; }
    else fwrite(buf, 1, (size_t)r, stdout);
  }
  close(fd);
  return err;
}

static int smc_opened;
int load_machine_quiet(void) {
  if (!smc_opened) { if (smc_open()) { snprintf(machine.err, sizeof machine.err, "AppleSMC not reachable"); return -1; } smc_opened = 1; }
  return machine_discover(&machine);
}

// SIGHUP to the guard, then wait until the controller reports the new reload
int reload_daemon(void) {
  FILE *f = fopen(GUARD_PID, "r"); int pid = 0;
  if (!f || fscanf(f, "%d", &pid) != 1 || pid <= 1) { if (f) fclose(f); fprintf(stderr, "no guard pid in %s (daemon not running?)\n", GUARD_PID); return 1; }
  fclose(f);
  static char st0[8192], st1[8192];
  ctl_client("STATUS", st0, sizeof st0);
  const char *r0 = strstr(st0, "(reloads "); unsigned g0 = r0 ? (unsigned)atoi(r0 + 9) : 0;
  if (kill(pid, SIGHUP)) { fprintf(stderr, "SIGHUP to guard %d: %s\n", pid, strerror(errno)); return 1; }
  for (int i = 0; i < 50; i++) {
    usleep(200000);
    if (ctl_client("STATUS", st1, sizeof st1)) continue;
    const char *r1 = strstr(st1, "(reloads "); unsigned g1 = r1 ? (unsigned)atoi(r1 + 9) : 0;
    if (g1 > g0) {
      const char *l = strstr(st1, "\nlearned "); char line[200] = "";
      if (l) { snprintf(line, sizeof line, "%s", l + 1); char *nl = strchr(line, '\n'); if (nl) *nl = 0; }
      printf("reloaded: %s\n", line);
      return strstr(line, "REFUSED") ? 3 : 0;
    }
  }
  fprintf(stderr, "the daemon did not report the reload within 10 s (see sofa-fand status)\n");
  return 1;
}

static int copy_file(const char *from, const char *to) {
  int in = open(from, O_RDONLY); if (in < 0) return -1;
  int out = open(to, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0644); if (out < 0) { close(in); return -1; }
  char b[8192]; ssize_t r; int ok = 0; size_t total = 0;
  while ((r = read(in, b, sizeof b)) > 0) { total += (size_t)r; if (total > 256 * 1024 || write(out, b, (size_t)r) != r) { ok = -1; break; } }
  if (r < 0) ok = -1;
  if (fchown(out, 0, 0) || fchmod(out, 0644) || fsync(out)) ok = -1;
  close(in); if (close(out)) ok = -1;
  return ok;
}

static int ensure_learned_dir(const char *path) {
  char dir[256]; snprintf(dir, sizeof dir, "%s", path); char *sl = strrchr(dir, '/'); if (!sl || sl == dir) return -1; *sl = 0;
  struct stat sd;
  if (lstat(dir, &sd) && (errno != ENOENT || mkdir(dir, 0755))) { fprintf(stderr, "%s: %s\n", dir, strerror(errno)); return -1; }
  if (lstat(dir, &sd) || !S_ISDIR(sd.st_mode) || sd.st_uid != 0) { fprintf(stderr, "%s is not a root directory\n", dir); return -1; }
  chmod(dir, 0755);
  return 0;
}

static int cmd_apply(const char *file, const char *conf, const char *dest) {
  if (geteuid()) { fprintf(stderr, "apply: root only\n"); return 1; }
  if (load_machine_quiet()) { fprintf(stderr, "apply: machine: %s\n", machine.err); return 1; }
  static cfg_t c;
  if (cfg_load(&c, conf, file, &machine)) { fprintf(stderr, "apply: reference invalid: %s\n", c.err); return 1; }
  if (c.learned < 0) { fprintf(stderr, "apply: refused: %s\n", c.err_learned); return 3; }
  if (ensure_learned_dir(dest)) return 1;
  char tmp[256]; snprintf(tmp, sizeof tmp, "%s.tmp", dest);
  char prev[256]; snprintf(prev, sizeof prev, "%s.prev", dest);
  unlink(tmp);
  if (copy_file(file, tmp)) { fprintf(stderr, "apply: cannot write %s: %s\n", tmp, strerror(errno)); unlink(tmp); return 1; }
  struct stat cur;
  if (lstat(dest, &cur) == 0) { unlink(prev); if (link(dest, prev)) { fprintf(stderr, "apply: cannot keep %s: %s\n", prev, strerror(errno)); unlink(tmp); return 1; } }
  else unlink(prev);                                         // none before: rollback = no layer
  if (rename(tmp, dest)) { fprintf(stderr, "apply: %s\n", strerror(errno)); unlink(tmp); return 1; }
  printf("installed %s (%u lines), previous kept as %s\n", dest, c.learned_lines, lstat(prev, &cur) == 0 ? prev : "none");
  return reload_daemon();
}

static int cmd_rollback(const char *dest) {
  if (geteuid()) { fprintf(stderr, "rollback: root only\n"); return 1; }
  char prev[256]; snprintf(prev, sizeof prev, "%s.prev", dest);
  struct stat s;
  if (lstat(prev, &s) == 0) { if (rename(prev, dest)) { fprintf(stderr, "rollback: %s\n", strerror(errno)); return 1; } printf("restored the previous learned layer\n"); }
  else if (lstat(dest, &s) == 0) { if (unlink(dest)) { fprintf(stderr, "rollback: %s\n", strerror(errno)); return 1; } printf("removed the learned layer (no previous one): reference only\n"); }
  else { printf("no learned layer installed\n"); return 0; }
  return reload_daemon();
}

int ctl_request(const char *cmd, char *out, size_t cap) { if (cap) out[0] = 0; return ctl_client(cmd, out, cap); }
int learned_install(const char *file, const char *conf) { return cmd_apply(file, conf, LEARNED_PATH); }
int learned_rollback(void) { return cmd_rollback(LEARNED_PATH); }

int main(int argc, char **argv) {
  const char *conf = CONF_PATH, *learned = LEARNED_PATH; int learned_given = 0;
  for (int i = 2; i + 1 < argc; i++) {
    if (!strcmp(argv[i], "-c")) conf = argv[i + 1];
    if (!strcmp(argv[i], "-l")) { learned = argv[i + 1]; learned_given = 1; }
  }
  for (int i = 2; i < argc; i++) if (!strcmp(argv[i], "-n")) dry = 1;
  const char *c1 = argc >= 2 ? argv[1] : "";
  if (!strcmp(c1, "run")) return run_daemon(conf, learned);
  if (!strcmp(c1, "learn")) return learn_main(argc, argv);
  if (!strcmp(c1, "init")) return init_main(argc, argv);
  if (!strcmp(c1, "migrate")) return migrate_main(argc, argv);
  if (!strcmp(c1, "identstop")) return ctl_client("IDENTSTOP", NULL, 0);
  if (!strcmp(c1, "ident") && argc >= 5) {      // ident SECS TAG RPM... (-1: curves) - root, Sofa resting
    char c[300]; size_t o = (size_t)snprintf(c, sizeof c, "IDENT %s %s", argv[2], argv[3]);
    for (int i = 4; i < argc && o < sizeof c; i++) if (strcmp(argv[i], "-n")) o += (size_t)snprintf(c + o, sizeof c - o, " %s", argv[i]);
    return ctl_client(c, NULL, 0);
  }
  if (!strcmp(c1, "hw")) {
    if (load_machine_quiet()) { fprintf(stderr, "machine: %s\n", machine.err[0] ? machine.err : "AppleSMC not reachable"); return 1; }
    machine_print(stdout, &machine); return 0;
  }
  if (!strcmp(c1, "check")) {
    int have = load_machine_quiet() == 0;
    if (!have) fprintf(stderr, "note: machine not readable (%s) - checked without it\n", machine.err[0] ? machine.err : "no SMC");
    if (cfg_load(&cfg, conf, learned_given ? learned : (access(LEARNED_PATH, R_OK) == 0 ? LEARNED_PATH : NULL), have ? &machine : NULL)) { fprintf(stderr, "%s\n", cfg.err); return 1; }
    cfg_print(stdout, &cfg);
    return cfg.learned < 0 ? 3 : 0;
  }
  if (!strcmp(c1, "apply") && argc >= 3) return cmd_apply(argv[2], conf, learned);   // -l: another target (tests with -n)
  if (!strcmp(c1, "rollback")) return cmd_rollback(learned);
  if (!strcmp(c1, "reload")) { if (geteuid()) { fprintf(stderr, "reload: root only\n"); return 1; } return reload_daemon(); }
  if (!strcmp(c1, "status")) return ctl_client("STATUS", NULL, 0);   // -n: the dry run's socket
  if (!strcmp(c1, "state")) return ctl_client("STATE", NULL, 0);
  if (argc >= 3 && !strcmp(argv[argc - 1], "-n")) argc--;            // hint ... -n: to the dry run
  if (argc >= 3 && argc <= 5 && !strcmp(c1, "hint")) {
    char c[300];
    snprintf(c, sizeof c, "HINT {\"v\":1,\"ctx\":\"%.16s\",\"vol\":%s,\"ttl\":%d,\"pid\":%d}", argv[2], argc >= 4 ? argv[3] : "null", argc >= 5 ? atoi(argv[4]) : 90, getpid());
    return ctl_client(c, NULL, 0);
  }
  if (argc == 2 && !strcmp(c1, "reset")) {
    if (load_machine_quiet() && !smc_opened) { fprintf(stderr, "FS! reset failed: %s\n", machine.err); return 1; }
    for (int n = 0; n < machine.nfans; n++) smc_set_fan_max(n, machine.fan[n].max);   // the loud fallback needs the limits
    if (smc_auto()) { fprintf(stderr, "FS! reset failed (root?)\n"); return 1; }
    printf("FS! = 0x%x (SMC regulates)\n", fs_get()); return 0;
  }
  fprintf(stderr, "usage: sofa-fand run [-c CONF] [-l LEARNED] [-n] | status [-n] | state [-n] | hint CTX [VOL] [TTL] | hw\n"
                  "       | check [-c CONF] [-l LEARNED] | apply FILE [-c CONF] [-l LEARNED] [-n] | rollback [-l LEARNED] [-n] | reload [-n] | reset\n"
                  "       | learn [-n] [-c CONF] [-d DATADIR] [-o REPORT] [--no-ident] | init [-o FILE] | migrate [LOGDIR]\n"
                  "       | ident SECS TAG RPM... [-n] | identstop [-n]\n");
  return 2;
}
