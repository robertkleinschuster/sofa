// sofa-fand - quiet fan control for Sofa's rest mode (iMac12,2, OS X 10.9).
//
// Outside rest mode the SMC regulates the fans as usual (FS! = 0). While Sofa signals rest mode
// over the control socket (QUIET <ttl>, renewed as a heartbeat), fans may run BELOW Apple's
// minimum, down to 0 rpm, following per-fan curves. Any doubt returns all fans to SMC control:
// stale heartbeat, a temperature limit, an unreadable sensor, an SMC error, a signal, a crash.
//
// Processes: launchd starts the guard (parent). The guard resets FS! = 0, forks the controller
// and watches it (waitpid + a heartbeat in shared memory). If the controller dies - even by
// SIGKILL - or hangs, the guard resets FS! = 0 at once and forks a new controller. Neither process
// execs or reads files after startup, so a vanished boot disk cannot stall the safety path.
//
//   sofa-fand run [-c CONF]   daemon (launchd, root)
//   sofa-fand status          state, temperatures, fans, recent log (via the socket)
//   sofa-fand quiet SECONDS   request rest mode for SECONDS (testing; Sofa uses the socket)
//   sofa-fand auto            end rest mode now
//   sofa-fand reset           FS! = 0 directly through the SMC (root, no daemon needed)
//   sofa-fand check [-c CONF] parse the config and print it
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/ata/ATASMARTLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <pthread.h>
#include <signal.h>
#include <syslog.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <poll.h>
#include <time.h>

#define SOCK_PATH   "/var/run/sofa-fand.sock"
#define CONF_PATH   "/usr/local/etc/sofa-fand.conf"
#define MAX_FANS    3
#define MAX_STEPS   8
#define MAX_LIMITS  16
#define MAX_TTL     120
#define LOOP_MS     2000
#define GUARD_STALE 15     // s without controller heartbeat -> guard takes over
#define HDD_SENSOR  "HDD"  // pseudo key: drive temperature from SMART attribute 194

// ---------------------------------------------------------------------------------------- SMC
typedef struct { char major, minor, build, reserved[1]; UInt16 release; } smc_vers_t;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } smc_plimit_t;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } smc_keyinfo_t;
typedef struct {
  UInt32 key; smc_vers_t vers; smc_plimit_t pLimitData; smc_keyinfo_t keyInfo;
  char result; char status; char data8; UInt32 data32; unsigned char bytes[32];
} smc_data_t;

static io_connect_t smc;

static UInt32 k2u(const char *s) { return ((UInt32)s[0]<<24)|((UInt32)s[1]<<16)|((UInt32)s[2]<<8)|(UInt32)s[3]; }

static int smc_open(void) {
  io_service_t svc = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSMC"));
  if (!svc) return -1;
  kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &smc);
  IOObjectRelease(svc);
  return kr == kIOReturnSuccess ? 0 : -1;
}

static int smc_call(smc_data_t *in, smc_data_t *out) {
  size_t sz = sizeof(*out);
  return IOConnectCallStructMethod(smc, 2, in, sizeof(*in), out, &sz) == kIOReturnSuccess ? 0 : -1;
}

static int smc_read(const char *key, unsigned char *buf, UInt32 *size, UInt32 *type) {
  smc_data_t in, out; memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
  in.key = k2u(key); in.data8 = 9;                                 // READ_KEYINFO
  if (smc_call(&in, &out) || out.result) return -1;
  *size = out.keyInfo.dataSize; *type = out.keyInfo.dataType;
  if (*size == 0 || *size > 32) return -1;
  in.keyInfo.dataSize = *size; in.data8 = 5;                       // READ_BYTES
  memset(&out, 0, sizeof out);
  if (smc_call(&in, &out) || out.result) return -1;
  memcpy(buf, out.bytes, *size);
  return 0;
}

static int smc_write(const char *key, const unsigned char *buf, UInt32 size) {
  smc_data_t in, out; memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
  in.key = k2u(key); in.data8 = 6; in.keyInfo.dataSize = size;     // WRITE_BYTES
  memcpy(in.bytes, buf, size);
  if (smc_call(&in, &out) || out.result) return -1;
  return 0;
}

// sp78 temperature; returns 0 and sets *t, -1 on any failure or implausible value
static int smc_temp(const char *key, double *t) {
  unsigned char b[32]; UInt32 sz, ty;
  if (smc_read(key, b, &sz, &ty) || ty != k2u("sp78") || sz != 2) return -1;
  double v = (signed char)b[0] + b[1] / 256.0;
  if (v < 5 || v > 125) return -1;
  *t = v; return 0;
}

static int smc_rpm(const char *key, double *r) {
  unsigned char b[32]; UInt32 sz, ty;
  if (smc_read(key, b, &sz, &ty) || ty != k2u("fpe2") || sz != 2) return -1;
  *r = ((b[0] << 8) | b[1]) / 4.0; return 0;
}

static int fs_get(void) {
  unsigned char b[32]; UInt32 sz, ty;
  if (smc_read("FS! ", b, &sz, &ty) || sz != 2) return -1;
  return (b[0] << 8) | b[1];
}

static int fs_set(int mask) {
  unsigned char b[2] = { (unsigned char)(mask >> 8), (unsigned char)(mask & 0xff) };
  return smc_write("FS! ", b, 2);
}

static int tg_set(int fan, int rpm) {
  char k[5]; snprintf(k, sizeof k, "F%dTg", fan);
  unsigned char b[2] = { (unsigned char)((rpm << 2) >> 8), (unsigned char)((rpm << 2) & 0xff) };
  return smc_write(k, b, 2);
}

// Back to SMC control. Retries; used on every exit path. Async-signal tolerant (one Mach call).
static int smc_auto(void) {
  for (int i = 0; i < 3; i++) if (fs_set(0) == 0 && fs_get() == 0) return 0;
  return -1;
}

// --------------------------------------------------------------------------------- monotonic
static double now_s(void) {
  static mach_timebase_info_data_t tb;
  if (!tb.denom) mach_timebase_info(&tb);
  return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

// ------------------------------------------------------------------- log (RAM ring + syslog)
// The control loop never blocks on logging: lines go into a ring buffer, a separate thread
// hands them to syslog. STATUS also returns the ring, so diagnosis needs no disk.
#define LOG_LINES 48
#define LOG_LEN   160
static char log_ring[LOG_LINES][LOG_LEN];
static unsigned log_head, log_sent;
static pthread_mutex_t log_mx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t log_cv = PTHREAD_COND_INITIALIZER;
static int log_threaded;

static void logf_(const char *fmt, ...) {
  char line[LOG_LEN]; time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm);
  int n = (int)strftime(line, sizeof line, "%m-%d %H:%M:%S ", &tm);
  va_list ap; va_start(ap, fmt); vsnprintf(line + n, sizeof line - n, fmt, ap); va_end(ap);
  if (!log_threaded) { syslog(LOG_NOTICE, "%s", line + n); fprintf(stderr, "%s\n", line); return; }
  pthread_mutex_lock(&log_mx);
  memcpy(log_ring[log_head % LOG_LINES], line, LOG_LEN);
  log_head++;
  pthread_cond_signal(&log_cv);
  pthread_mutex_unlock(&log_mx);
}

static void *log_thread(void *arg) {
  (void)arg;
  for (;;) {
    char line[LOG_LEN];
    pthread_mutex_lock(&log_mx);
    while (log_sent == log_head) pthread_cond_wait(&log_cv, &log_mx);
    if (log_head - log_sent > LOG_LINES) log_sent = log_head - LOG_LINES;
    memcpy(line, log_ring[log_sent % LOG_LINES], LOG_LEN);
    log_sent++;
    pthread_mutex_unlock(&log_mx);
    syslog(LOG_NOTICE, "%s", line + 15);    // syslog adds its own timestamp
  }
  return NULL;
}

// ------------------------------------------------------------------------------------ config
typedef struct { char key[8]; double max; } limit_t;
typedef struct { double below; int rpm; } step_t;      // temp < below -> rpm (in ascending order)
typedef struct {
  int used; char sensor[8]; double hyst; int nsteps; step_t steps[MAX_STEPS];
  int floor;    // never force below this rpm (0 = may stop)
} fancfg_t;
typedef struct {
  int nlimits; limit_t limits[MAX_LIMITS];
  fancfg_t fan[MAX_FANS];
  int hdd_interval, hdd_stale;     // s
  int trip_holdoff;                // s in AUTO after a limit/fault trip
  int allow_uid;                   // besides root, may send QUIET/AUTO (-1 = any)
  int ok; char err[160];
} cfg_t;

static cfg_t cfg;

static void cfg_defaults(cfg_t *c) {
  memset(c, 0, sizeof *c);
  c->hdd_interval = 30; c->hdd_stale = 120; c->trip_holdoff = 600; c->allow_uid = 501;
  c->ok = 1;
}

static int cfg_load(cfg_t *c, const char *path) {
  cfg_defaults(c);
  FILE *f = fopen(path, "r");
  if (!f) { snprintf(c->err, sizeof c->err, "%s: %s", path, strerror(errno)); c->ok = 0; return -1; }
  char line[512]; int ln = 0;
  while (fgets(line, sizeof line, f)) {
    ln++;
    char *h = strchr(line, '#'); if (h) *h = 0;
    char *tok[24]; int nt = 0;
    for (char *p = strtok(line, " \t\r\n"); p && nt < 24; p = strtok(NULL, " \t\r\n")) tok[nt++] = p;
    if (!nt) continue;
    if (!strcmp(tok[0], "limit") && nt == 3 && c->nlimits < MAX_LIMITS && strlen(tok[1]) <= 4) {
      limit_t *l = &c->limits[c->nlimits++];
      snprintf(l->key, sizeof l->key, "%s", tok[1]); l->max = atof(tok[2]);
      if (l->max < 20 || l->max > 110) goto bad;
    } else if (!strcmp(tok[0], "fan") && nt >= 6) {
      // fan N sensor KEY hyst H [floor R] steps T:R T:R ...
      int n = atoi(tok[1]); if (n < 0 || n >= MAX_FANS || c->fan[n].used) goto bad;
      fancfg_t *fc = &c->fan[n]; fc->used = 1;
      int i = 2;
      for (; i < nt; i++) {
        if (!strcmp(tok[i], "sensor") && i + 1 < nt) { if (strlen(tok[++i]) > 4) goto bad; snprintf(fc->sensor, sizeof fc->sensor, "%s", tok[i]); }
        else if (!strcmp(tok[i], "hyst") && i + 1 < nt) fc->hyst = atof(tok[++i]);
        else if (!strcmp(tok[i], "floor") && i + 1 < nt) fc->floor = atoi(tok[++i]);
        else if (!strcmp(tok[i], "steps")) { i++; break; }
        else goto bad;
      }
      for (; i < nt; i++) {
        double t; int r;
        if (fc->nsteps >= MAX_STEPS || sscanf(tok[i], "%lf:%d", &t, &r) != 2) goto bad;
        if (r < 0 || r > 3000 || t < 20 || t > 100) goto bad;
        if (fc->nsteps && (t <= fc->steps[fc->nsteps-1].below || r < fc->steps[fc->nsteps-1].rpm)) goto bad;
        fc->steps[fc->nsteps].below = t; fc->steps[fc->nsteps].rpm = r; fc->nsteps++;
      }
      if (!fc->sensor[0] || !fc->nsteps || fc->hyst < 0.5 || fc->hyst > 10) goto bad;
    } else if (!strcmp(tok[0], "hdd_interval") && nt == 2) c->hdd_interval = atoi(tok[1]);
    else if (!strcmp(tok[0], "hdd_stale") && nt == 2) c->hdd_stale = atoi(tok[1]);
    else if (!strcmp(tok[0], "trip_holdoff") && nt == 2) c->trip_holdoff = atoi(tok[1]);
    else if (!strcmp(tok[0], "allow_uid") && nt == 2) c->allow_uid = atoi(tok[1]);
    else goto bad;
    continue;
  bad:
    snprintf(c->err, sizeof c->err, "%s:%d: invalid line", path, ln); c->ok = 0; fclose(f); return -1;
  }
  fclose(f);
  if (c->hdd_interval < 5 || c->hdd_stale < 2 * c->hdd_interval) { snprintf(c->err, sizeof c->err, "hdd_interval/hdd_stale invalid"); c->ok = 0; return -1; }
  // Every fan's control sensor must also carry a limit: a sensor that steers a fan is always guarded.
  for (int n = 0; n < MAX_FANS; n++) if (c->fan[n].used) {
    int found = 0;
    for (int i = 0; i < c->nlimits; i++) if (!strcmp(c->limits[i].key, c->fan[n].sensor)) found = 1;
    if (!found) { snprintf(c->err, sizeof c->err, "fan %d: sensor %s has no limit", n, c->fan[n].sensor); c->ok = 0; return -1; }
  }
  return 0;
}

static void cfg_print(FILE *o, const cfg_t *c) {
  for (int i = 0; i < c->nlimits; i++) fprintf(o, "limit %s %.1f\n", c->limits[i].key, c->limits[i].max);
  for (int n = 0; n < MAX_FANS; n++) if (c->fan[n].used) {
    const fancfg_t *f = &c->fan[n];
    fprintf(o, "fan %d sensor %s hyst %.1f floor %d steps", n, f->sensor, f->hyst, f->floor);
    for (int i = 0; i < f->nsteps; i++) fprintf(o, " %.1f:%d", f->steps[i].below, f->steps[i].rpm);
    fprintf(o, " (above: SMC)\n");
  }
  fprintf(o, "hdd_interval %d hdd_stale %d trip_holdoff %d allow_uid %d\n", c->hdd_interval, c->hdd_stale, c->trip_holdoff, c->allow_uid);
}

// ----------------------------------------------------------------------- SMART drive temp
// Read in its own thread: if the drive hangs, only this thread blocks; the value then goes
// stale and the controller falls back to AUTO.
static volatile double hdd_temp = -1, hdd_when = -1e9;
static volatile int hdd_fail;
static IOATASMARTInterface **smart_if;

static int smart_open(void) {
  io_iterator_t it; io_object_t o;
  if (IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IOBlockStorageDevice"), &it)) return -1;
  while ((o = IOIteratorNext(it))) {
    CFTypeRef cap = IORegistryEntrySearchCFProperty(o, kIOServicePlane, CFSTR("SMART Capable"), kCFAllocatorDefault, 0);
    if (cap && !smart_if) {
      IOCFPlugInInterface **pi = NULL; SInt32 score;
      if (!IOCreatePlugInInterfaceForService(o, kIOATASMARTUserClientTypeID, kIOCFPlugInInterfaceID, &pi, &score) && pi) {
        (*pi)->QueryInterface(pi, CFUUIDGetUUIDBytes(kIOATASMARTInterfaceID), (LPVOID *)&smart_if);
        (*pi)->Release(pi);
      }
    }
    if (cap) CFRelease(cap);
    IOObjectRelease(o);
  }
  IOObjectRelease(it);
  return smart_if ? 0 : -1;
}

static void *smart_thread(void *arg) {
  (void)arg;
  for (;;) {
    int t = -1;
    if (smart_if || smart_open() == 0) {
      ATASMARTData d; memset(&d, 0, sizeof d);
      if ((*smart_if)->SMARTReadData(smart_if, &d) == kIOReturnSuccess) {
        unsigned char *b = (unsigned char *)&d;
        for (int i = 0; i < 30; i++) { unsigned char *a = b + 2 + i * 12; if (a[0] == 194) { t = a[5]; break; } }
      }
    }
    if (t > 5 && t < 90) { hdd_temp = t; hdd_when = now_s(); hdd_fail = 0; }
    else hdd_fail++;
    sleep(cfg.hdd_interval);
  }
  return NULL;
}

// ------------------------------------------------------------------------- shared with guard
typedef struct { volatile double beat; volatile int forced; } shared_t;
static shared_t *shm;

// ------------------------------------------------------------------------------- controller
typedef enum { M_AUTO, M_QUIET, M_TRIP, M_DISABLED } mode_t_;
static const char *mode_name[] = { "auto", "quiet", "trip", "disabled" };

static struct {
  mode_t_ mode; char reason[96];
  double quiet_until, trip_until;
  int level[MAX_FANS];            // current step index per fan, nsteps = SMC
  int forced_mask; int target[MAX_FANS];
  double temp[MAX_LIMITS]; int temp_ok[MAX_LIMITS];
  double fan_ac[MAX_FANS];
  double stall_since[MAX_FANS];   // forced to >0 rpm but the fan does not turn
  int lock_ok; unsigned long locked_kb;
  double started;
} st;

static int fan_count;

static void go_auto(mode_t_ m, const char *reason) {
  int failed = smc_auto();
  if (st.mode != m || strcmp(st.reason, reason)) logf_("-> %s (%s)%s", mode_name[m], reason, failed ? " FS! RESET FAILED" : "");
  st.mode = m; snprintf(st.reason, sizeof st.reason, "%s", reason);
  st.forced_mask = 0;
  for (int n = 0; n < MAX_FANS; n++) { st.level[n] = cfg.fan[n].nsteps; st.target[n] = 0; st.stall_since[n] = 0; }
  shm->forced = 0;
}

static int read_sensor(const char *key, double *t, double now) {
  if (!strcmp(key, HDD_SENSOR)) {
    if (hdd_temp < 0 || now - hdd_when > cfg.hdd_stale) return -1;
    *t = hdd_temp; return 0;
  }
  char k[5] = "    "; memcpy(k, key, strlen(key) > 4 ? 4 : strlen(key));
  return smc_temp(k, t);
}

static void control_step(void) {
  double now = now_s();
  char why[96];
  // fan speeds for status (errors here are not fatal)
  for (int n = 0; n < fan_count; n++) { char k[5]; snprintf(k, 5, "F%dAc", n); if (smc_rpm(k, &st.fan_ac[n])) st.fan_ac[n] = -1; }
  // sensors + limits are checked in every mode (status shows them; trips are remembered)
  int bad = -1, over = -1;
  for (int i = 0; i < cfg.nlimits; i++) {
    st.temp_ok[i] = read_sensor(cfg.limits[i].key, &st.temp[i], now) == 0;
    if (!st.temp_ok[i] && bad < 0) bad = i;
    else if (st.temp_ok[i] && st.temp[i] >= cfg.limits[i].max && over < 0) over = i;
  }
  if (st.mode == M_DISABLED) { if (fs_get() != 0) go_auto(M_DISABLED, st.reason); return; }

  int quiet = now < st.quiet_until;
  if (!quiet) { if (st.mode != M_TRIP || now >= st.trip_until) { if (st.mode != M_AUTO || st.forced_mask || fs_get() != 0) go_auto(M_AUTO, "no rest mode"); } else if (fs_get() != 0) go_auto(M_TRIP, st.reason); return; }
  if (st.mode == M_TRIP && now < st.trip_until) { if (fs_get() != 0) go_auto(M_TRIP, st.reason); return; }
  if (over >= 0) {
    snprintf(why, sizeof why, "limit %s %.1f >= %.1f", cfg.limits[over].key, st.temp[over], cfg.limits[over].max);
    go_auto(M_TRIP, why); st.trip_until = now + cfg.trip_holdoff; return;
  }
  if (bad >= 0 && !strcmp(cfg.limits[bad].key, HDD_SENSOR) && hdd_when < 0 && now - st.started < cfg.hdd_stale) {
    // first SMART reading not there yet (just started): wait in AUTO, this is no fault
    if (st.mode != M_AUTO || fs_get() != 0) go_auto(M_AUTO, "waiting for sensors");
    return;
  }
  if (bad >= 0) {
    snprintf(why, sizeof why, "sensor %s unreadable", cfg.limits[bad].key);
    go_auto(M_TRIP, why); st.trip_until = now + cfg.trip_holdoff; return;
  }

  // curves: per fan pick the step; with hysteresis on the way down
  int mask = 0;
  for (int n = 0; n < fan_count && n < MAX_FANS; n++) {
    fancfg_t *fc = &cfg.fan[n];
    if (!fc->used) continue;
    double t = 0; int idx = -1;
    for (int i = 0; i < cfg.nlimits; i++) if (!strcmp(cfg.limits[i].key, fc->sensor)) idx = i;
    t = st.temp[idx];
    int want = fc->nsteps;                                  // nsteps = above all steps -> SMC
    for (int s = 0; s < fc->nsteps; s++) if (t < fc->steps[s].below) { want = s; break; }
    int cur = st.level[n];
    if (want < cur) {                                       // cooler: only step down past hysteresis
      int s = cur;
      while (s > 0 && t < fc->steps[s - 1].below - fc->hyst) s--;
      want = s;
    }
    st.level[n] = want;
    if (want < fc->nsteps) {
      int rpm = fc->steps[want].rpm; if (rpm < fc->floor) rpm = fc->floor;
      if (tg_set(n, rpm)) { go_auto(M_TRIP, "SMC write failed"); st.trip_until = now + cfg.trip_holdoff; return; }
      st.target[n] = rpm; mask |= 1 << n;
    } else st.target[n] = 0;
    // a fan asked to turn must turn (it may not start from 0 at a low duty cycle)
    if (st.target[n] > 0 && (st.forced_mask & (1 << n)) && st.fan_ac[n] < st.target[n] / 2.0) {
      if (!st.stall_since[n]) st.stall_since[n] = now;
      else if (now - st.stall_since[n] > 20) {
        snprintf(why, sizeof why, "fan %d stalled (%.0f rpm, wanted %d)", n, st.fan_ac[n], st.target[n]);
        go_auto(M_TRIP, why); st.trip_until = now + cfg.trip_holdoff; return;
      }
    } else st.stall_since[n] = 0;
  }
  if (fs_set(mask) || fs_get() != mask) { go_auto(M_TRIP, "SMC write failed"); st.trip_until = now + cfg.trip_holdoff; return; }
  shm->forced = mask;
  if (st.mode != M_QUIET || mask != st.forced_mask) {
    char d[96] = ""; int p = 0;
    for (int n = 0; n < fan_count && n < MAX_FANS; n++) {
      if (mask & (1 << n)) p += snprintf(d + p, sizeof d - p, " F%d=%d", n, st.target[n]);
      else p += snprintf(d + p, sizeof d - p, " F%d=smc", n);
    }
    logf_("quiet:%s", d);
  }
  st.mode = M_QUIET; snprintf(st.reason, sizeof st.reason, "rest mode");
  st.forced_mask = mask;
}

static int status_text(char *buf, size_t cap) {
  double now = now_s(); size_t p = 0;
  #define OUT(...) do { int _n = snprintf(buf + p, p < cap ? cap - p : 0, __VA_ARGS__); if (_n > 0) p += (size_t)_n; } while (0)
  OUT("mode %s (%s)\n", mode_name[st.mode], st.reason);
  OUT("quiet_remaining %.0f\n", st.quiet_until > now ? st.quiet_until - now : 0);
  if (st.mode == M_TRIP) OUT("trip_remaining %.0f\n", st.trip_until > now ? st.trip_until - now : 0);
  OUT("fs 0x%x\n", fs_get());
  for (int n = 0; n < fan_count && n < MAX_FANS; n++)
    OUT("fan %d actual %.0f %s %d\n", n, st.fan_ac[n], (st.forced_mask & (1 << n)) ? "forced" : "smc", st.target[n]);
  for (int i = 0; i < cfg.nlimits; i++) {
    if (st.temp_ok[i]) OUT("temp %s %.1f limit %.1f\n", cfg.limits[i].key, st.temp[i], cfg.limits[i].max);
    else OUT("temp %s unreadable limit %.1f\n", cfg.limits[i].key, cfg.limits[i].max);
  }
  OUT("hdd_age %.0f\n", hdd_when > 0 ? now - hdd_when : -1);
  OUT("memlock %s %lu KB\n", st.lock_ok ? "all" : "segments", st.locked_kb);
  OUT("uptime %.0f\n", now - st.started);
  pthread_mutex_lock(&log_mx);
  unsigned from = log_head > 12 ? log_head - 12 : 0;
  for (unsigned i = from; i < log_head; i++) OUT("log %s\n", log_ring[i % LOG_LINES]);
  pthread_mutex_unlock(&log_mx);
  OUT(".\n");
  #undef OUT
  return (int)(p < cap ? p : cap - 1);
}

// one command line per connection; short timeouts so a stuck client cannot stall the loop
static int handle_client(int fd) {
  struct timeval tv = { 0, 300000 };
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
  int on = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
  char cmd[128]; ssize_t n = 0;
  while (n < (ssize_t)sizeof cmd - 1) {
    ssize_t r = read(fd, cmd + n, sizeof cmd - 1 - n);
    if (r <= 0) break;
    n += r; if (memchr(cmd, '\n', n)) break;
  }
  if (n <= 0) { close(fd); return 0; }
  cmd[n] = 0; char *nl = strpbrk(cmd, "\r\n"); if (nl) *nl = 0;
  uid_t uid = (uid_t)-1; gid_t gid; getpeereid(fd, &uid, &gid);
  int may = uid == 0 || cfg.allow_uid < 0 || (int)uid == cfg.allow_uid;
  static char out[6144]; int len;
  if (!strncmp(cmd, "QUIET ", 6)) {
    int ttl = atoi(cmd + 6);
    if (!may) len = snprintf(out, sizeof out, "ERR permission\n");
    else if (ttl < 1 || ttl > MAX_TTL) len = snprintf(out, sizeof out, "ERR ttl 1..%d\n", MAX_TTL);
    else {
      int was = now_s() < st.quiet_until;
      st.quiet_until = now_s() + ttl;
      if (!was) logf_("rest mode requested (uid %d, ttl %d)", (int)uid, ttl);
      len = snprintf(out, sizeof out, "OK %s\n", mode_name[st.mode]);
    }
  } else if (!strcmp(cmd, "AUTO")) {
    if (!may) len = snprintf(out, sizeof out, "ERR permission\n");
    else { if (now_s() < st.quiet_until) logf_("rest mode ended (uid %d)", (int)uid); st.quiet_until = 0; len = snprintf(out, sizeof out, "OK\n"); }
  } else if (!strcmp(cmd, "STATUS")) len = status_text(out, sizeof out);
  else len = snprintf(out, sizeof out, "ERR unknown command\n");
  ssize_t w = write(fd, out, (size_t)len); (void)w;
  close(fd);
  return !strncmp(cmd, "QUIET ", 6) || !strcmp(cmd, "AUTO");   // react in this loop turn
}

static void ctl_crash(int sig) { fs_set(0); fs_set(0); _exit(128 + sig); }
static volatile sig_atomic_t ctl_stop;
static void ctl_term(int sig) { (void)sig; ctl_stop = 1; }

static void lock_memory(void) {
  if (mlockall(MCL_CURRENT | MCL_FUTURE) == 0) { st.lock_ok = 1; return; }
  // Darwin does not implement mlockall: wire every loaded image's segments instead (own binary,
  // IOKit, CoreFoundation, libSystem ...), so no page of the code we run must come from disk.
  unsigned long kb = 0;
  for (uint32_t i = 0; i < _dyld_image_count(); i++) {
    const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
    intptr_t slide = _dyld_get_image_vmaddr_slide(i);
    const struct load_command *lc = (const struct load_command *)(mh + 1);
    for (uint32_t j = 0; j < mh->ncmds; j++, lc = (const struct load_command *)((const char *)lc + lc->cmdsize)) {
      if (lc->cmd != LC_SEGMENT_64) continue;
      const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
      if (!strcmp(sg->segname, "__PAGEZERO") || !strcmp(sg->segname, "__LINKEDIT") || !sg->vmsize) continue;
      if (mlock((void *)(sg->vmaddr + slide), sg->vmsize) == 0) kb += sg->vmsize / 1024;
    }
  }
  st.locked_kb = kb;
}

static void controller(int lfd) {
  signal(SIGTERM, ctl_term); signal(SIGINT, ctl_term); signal(SIGHUP, SIG_IGN); signal(SIGPIPE, SIG_IGN);
  signal(SIGSEGV, ctl_crash); signal(SIGBUS, ctl_crash); signal(SIGILL, ctl_crash);
  signal(SIGFPE, ctl_crash); signal(SIGABRT, ctl_crash);
  if (smc_open()) { logf_("controller: AppleSMC not reachable"); _exit(1); }
  smc_auto();
  atexit((void (*)(void))smc_auto);
  st.started = now_s();
  for (int n = 0; n < MAX_FANS; n++) st.level[n] = cfg.fan[n].nsteps;
  unsigned char b[32]; UInt32 sz, ty;
  fan_count = smc_read("FNum", b, &sz, &ty) == 0 ? b[0] : 0;
  if (fan_count > MAX_FANS) fan_count = MAX_FANS;
  st.mode = M_AUTO; snprintf(st.reason, sizeof st.reason, "start");
  if (!cfg.ok) { st.mode = M_DISABLED; snprintf(st.reason, sizeof st.reason, "config: %.80s", cfg.err); }
  pthread_t th;
  log_threaded = 1;
  pthread_create(&th, NULL, log_thread, NULL);
  pthread_create(&th, NULL, smart_thread, NULL);
  lock_memory();
  static char prefault[256 * 1024]; memset(prefault, 0, sizeof prefault);   // stack/heap warm-up
  logf_("controller up (pid %d, %d fans, memlock %s %lu KB)%s%s", getpid(), fan_count,
        st.lock_ok ? "all" : "segments", st.locked_kb, cfg.ok ? "" : ", DISABLED: ", cfg.ok ? "" : cfg.err);
  double next = now_s();
  while (!ctl_stop) {
    double now = now_s();
    if (now >= next) { control_step(); shm->beat = now_s(); next = now + LOOP_MS / 1000.0; }
    struct pollfd p = { lfd, POLLIN, 0 };
    int to = (int)((next - now_s()) * 1000); if (to < 0) to = 0;
    if (poll(&p, 1, to) > 0 && (p.revents & POLLIN)) {
      int fd = accept(lfd, NULL, NULL);
      if (fd >= 0 && handle_client(fd)) next = now_s();
    }
  }
  smc_auto(); shm->forced = 0;
  logf_("controller stopped, FS!=0");
  usleep(200000);                 // let the log thread flush
  _exit(0);
}

// ------------------------------------------------------------------------------------ guard
static volatile sig_atomic_t guard_stop;
static void guard_term(int sig) { (void)sig; guard_stop = 1; }

static int run_daemon(const char *conf) {
  // 1. Safety first: whatever a previous instance left behind, the SMC regulates again.
  openlog("sofa-fand", LOG_PID, LOG_DAEMON);
  if (smc_open()) { syslog(LOG_ERR, "AppleSMC not reachable"); return 1; }
  if (smc_auto()) syslog(LOG_ERR, "FS! reset failed at start");
  // 2. Config once, never again.
  cfg_load(&cfg, conf);
  if (!cfg.ok) syslog(LOG_ERR, "config: %s - staying in AUTO", cfg.err);
  // 3. Control socket (created by the guard, inherited by every controller).
  int lfd = socket(AF_UNIX, SOCK_STREAM, 0);
  struct sockaddr_un sa; memset(&sa, 0, sizeof sa); sa.sun_family = AF_UNIX;
  snprintf(sa.sun_path, sizeof sa.sun_path, "%s", SOCK_PATH);
  unlink(SOCK_PATH);
  if (lfd < 0 || bind(lfd, (struct sockaddr *)&sa, sizeof sa) || listen(lfd, 8)) { syslog(LOG_ERR, "socket %s: %m", SOCK_PATH); return 1; }
  chmod(SOCK_PATH, 0666);
  fcntl(lfd, F_SETFL, O_NONBLOCK);
  shm = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
  if (shm == MAP_FAILED) return 1;
  mlock(shm, 4096);
  signal(SIGTERM, guard_term); signal(SIGINT, guard_term); signal(SIGHUP, SIG_IGN); signal(SIGPIPE, SIG_IGN);
  lock_memory();
  syslog(LOG_NOTICE, "guard up (pid %d)", getpid());
  int restarts = 0; double window = now_s();
  while (!guard_stop) {
    shm->beat = now_s(); shm->forced = 0;
    pid_t child = fork();
    if (child == 0) controller(lfd);
    if (child < 0) { smc_auto(); sleep(5); continue; }
    while (!guard_stop) {
      int stv; pid_t r = waitpid(child, &stv, WNOHANG);
      if (r == child) {
        // controller gone (crash, SIGKILL ...): back to SMC control before anything else
        int failed = smc_auto();
        syslog(LOG_ERR, "controller %d ended (%s %d), FS!=0%s", child, WIFSIGNALED(stv) ? "signal" : "exit",
               WIFSIGNALED(stv) ? WTERMSIG(stv) : WEXITSTATUS(stv), failed ? " FAILED" : "");
        break;
      }
      if (now_s() - shm->beat > GUARD_STALE) {
        smc_auto();
        kill(child, SIGKILL); waitpid(child, &stv, 0);
        smc_auto();
        syslog(LOG_ERR, "controller %d hung (no heartbeat %ds), killed, FS!=0", child, GUARD_STALE);
        break;
      }
      // belt and braces: fans forced although the controller says it does not force
      if (shm->forced == 0 && now_s() - shm->beat < 5) { int fs = fs_get(); if (fs > 0) { usleep(500000); if (shm->forced == 0 && fs_get() > 0) { smc_auto(); syslog(LOG_ERR, "FS! set without controller request, reset"); } } }
      usleep(500000);
    }
    if (guard_stop) {
      kill(child, SIGTERM);
      for (int i = 0; i < 20 && waitpid(child, NULL, WNOHANG) == 0; i++) usleep(100000);
      kill(child, SIGKILL); waitpid(child, NULL, 0);
      break;
    }
    if (now_s() - window > 300) { window = now_s(); restarts = 0; }
    if (++restarts > 5) { syslog(LOG_ERR, "controller keeps failing, pausing 60 s (fans: SMC)"); smc_auto(); sleep(60); restarts = 0; }
    else sleep(2);
  }
  smc_auto();
  unlink(SOCK_PATH);
  syslog(LOG_NOTICE, "guard stopped, FS!=0 (0x%x)", fs_get());
  return 0;
}

// ----------------------------------------------------------------------------------- client
static int client(const char *cmd) {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  struct sockaddr_un sa; memset(&sa, 0, sizeof sa); sa.sun_family = AF_UNIX;
  snprintf(sa.sun_path, sizeof sa.sun_path, "%s", SOCK_PATH);
  struct timeval tv = { 3, 0 };
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  if (fd < 0 || connect(fd, (struct sockaddr *)&sa, sizeof sa)) { fprintf(stderr, "sofa-fand not reachable (%s)\n", SOCK_PATH); return 1; }
  char line[160]; int n = snprintf(line, sizeof line, "%s\n", cmd);
  if (write(fd, line, (size_t)n) != n) return 1;
  char buf[4096]; ssize_t r; int err = 0;
  while ((r = read(fd, buf, sizeof buf)) > 0) { fwrite(buf, 1, (size_t)r, stdout); if (!strncmp(buf, "ERR", 3)) err = 1; }
  close(fd);
  return err;
}

int main(int argc, char **argv) {
  const char *conf = CONF_PATH;
  for (int i = 2; i + 1 < argc; i++) if (!strcmp(argv[i], "-c")) conf = argv[i + 1];
  if (argc >= 2 && !strcmp(argv[1], "run")) return run_daemon(conf);
  if (argc >= 2 && !strcmp(argv[1], "check")) {
    cfg_load(&cfg, conf);
    if (!cfg.ok) { fprintf(stderr, "%s\n", cfg.err); return 1; }
    cfg_print(stdout, &cfg); return 0;
  }
  if (argc == 2 && !strcmp(argv[1], "status")) return client("STATUS");
  if (argc == 2 && !strcmp(argv[1], "auto")) return client("AUTO");
  if (argc == 3 && !strcmp(argv[1], "quiet")) { char c[32]; snprintf(c, sizeof c, "QUIET %d", atoi(argv[2])); return client(c); }
  if (argc == 2 && !strcmp(argv[1], "reset")) {
    if (smc_open() || smc_auto()) { fprintf(stderr, "FS! reset failed (root?)\n"); return 1; }
    printf("FS! = 0x%x (SMC regulates)\n", fs_get()); return 0;
  }
  fprintf(stderr, "usage: sofa-fand run [-c CONF] | status | quiet SECONDS | auto | reset | check [-c CONF]\n");
  return 2;
}
