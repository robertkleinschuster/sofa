// sofa-fand - always-on fan control for the iMac12,2 (27", Mid 2011, OS X 10.9).
//
// Emulates "fan minimum = 0" with its own curves: cool -> fans down to 0 rpm, warm -> more
// speed than Apple's SMC would run (Apple keeps every fan at its minimum until a sensor reaches
// its own fan threshold). The daemon drives all fans in the SMC's forced mode (FS! + F<n>Tg);
// the SMC regulates again (FS! = 0) on every fault: unreadable sensor, SMC error, a fan that
// does not turn, crash, SIGKILL, hang, stop. A temperature limit instead forces every fan to
// its maximum (more cooling than the SMC would give at that point).
//
// Sofa may send a context hint (playback + volume / idle / ruhe) that shifts the curves; without
// a fresh hint the default profile applies. Hints never touch limits or floors.
//
// Processes: launchd starts the guard; it resets FS! = 0, reads the config, binds the sockets and
// forks the controller. If the controller dies (even SIGKILL) or stops beating, the guard resets
// FS! = 0 at once and forks a new one - no exec, no disk. The controller's control loop does no
// file or socket I/O: sockets live in their own thread, SMART reads in another, logging in a third.
//
//   sofa-fand run [-c CONF]      daemon (launchd, root)
//   sofa-fand status             state, fans, temperatures, recent log (ctl socket)
//   sofa-fand hint CTX [VOL] [TTL]  send a context hint like Sofa does (testing)
//   sofa-fand reset              FS! = 0 directly through the SMC (root, no daemon needed)
//   sofa-fand check [-c CONF]    parse the config and print it
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/ata/ATASMARTLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/time.h>
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
#include <math.h>
#include <stddef.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOMessage.h>

int pthread_setugid_np(uid_t uid, gid_t gid);   // Darwin: per-thread credentials (sys/pthread)

#define RUN_DIR     "/var/run/sofa-fand"
#define HINT_SOCK   RUN_DIR "/hint.sock"
#define CTL_SOCK    RUN_DIR "/ctl.sock"
#define CONF_PATH   "/usr/local/etc/sofa-fand.conf"
#define MAX_FANS    3
#define MAX_SENS    24
#define MAX_PTS     8
#define MAX_CURVES  8
#define MAX_FLOORS  8
#define LOOP_S      2.0
#define GUARD_STALE 15.0
#define HDD_KEY     "HDD"
#define HINT_MAX    512

// ============================================================================== SMC access
typedef struct { char major, minor, build, reserved[1]; UInt16 release; } smc_vers_t;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } smc_plimit_t;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } smc_keyinfo_t;
typedef struct {
  UInt32 key; smc_vers_t vers; smc_plimit_t pLimitData; smc_keyinfo_t keyInfo;
  char result; char status; char data8; UInt32 data32; unsigned char bytes[32];
} smc_data_t;

static io_connect_t smc;   // per process (Mach ports do not survive fork)
static int dry;            // -n: compute and report, never write the SMC (FS!/F<n>Tg)
static int dry_fs;         // what FS! would be in dry mode

static UInt32 k2u(const char *s) { return ((UInt32)(unsigned char)s[0]<<24)|((UInt32)(unsigned char)s[1]<<16)|((UInt32)(unsigned char)s[2]<<8)|(UInt32)(unsigned char)s[3]; }

static int smc_open(void) {
  io_service_t svc = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSMC"));
  if (!svc) return -1;
  kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &smc);
  IOObjectRelease(svc);
  return kr == kIOReturnSuccess ? 0 : -1;
}

static int smc_call(smc_data_t *in, smc_data_t *out) {
  size_t sz = sizeof(*out);
  return IOConnectCallStructMethod(smc, 2, in, sizeof(*in), out, &sz) == kIOReturnSuccess && sz == sizeof(*out) ? 0 : -1;
}

static int smc_read(const char *key, unsigned char *buf, UInt32 *size, UInt32 *type) {
  smc_data_t in, out; memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
  in.key = k2u(key); in.data8 = 9;                                   // READ_KEYINFO
  if (smc_call(&in, &out) || out.result) return -1;
  *size = out.keyInfo.dataSize; *type = out.keyInfo.dataType;
  if (*size == 0 || *size > 32) return -1;
  in.keyInfo.dataSize = *size; in.data8 = 5;                         // READ_BYTES
  memset(&out, 0, sizeof out);
  if (smc_call(&in, &out) || out.result) return -1;
  memcpy(buf, out.bytes, *size);
  return 0;
}

static int smc_write(const char *key, const unsigned char *buf, UInt32 size) {
  smc_data_t in, out; memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
  in.key = k2u(key); in.data8 = 6; in.keyInfo.dataSize = size;       // WRITE_BYTES
  memcpy(in.bytes, buf, size);
  if (smc_call(&in, &out) || out.result) return -1;
  return 0;
}

static int key_ok(const char *k) { size_t n = strlen(k); if (n < 1 || n > 4) return 0; for (size_t i = 0; i < n; i++) if (k[i] < 0x20 || k[i] > 0x7e) return 0; return 1; }

// sp78 temperature, plausible range only; one retry for a transient SMC hiccup
static int smc_temp(const char *key4, double *t) {
  for (int a = 0; a < 2; a++) {
    unsigned char b[32]; UInt32 sz, ty;
    if (smc_read(key4, b, &sz, &ty) == 0 && ty == k2u("sp78") && sz == 2) {
      double v = (signed char)b[0] + b[1] / 256.0;
      if (v >= 5 && v <= 125) { *t = v; return 0; }
    }
    usleep(20000);
  }
  return -1;
}

static int smc_fpe2(const char *key4, double *r) {
  unsigned char b[32]; UInt32 sz, ty;
  if (smc_read(key4, b, &sz, &ty) || ty != k2u("fpe2") || sz != 2) return -1;
  *r = ((b[0] << 8) | b[1]) / 4.0; return 0;
}

static int fs_get(void) {
  if (dry) return dry_fs;
  unsigned char b[32]; UInt32 sz, ty;
  if (smc_read("FS! ", b, &sz, &ty) || sz != 2) return -1;
  return (b[0] << 8) | b[1];
}

static int fs_set(int mask) {
  if (dry) { dry_fs = mask; return 0; }
  unsigned char b[2] = { (unsigned char)((mask >> 8) & 0xff), (unsigned char)(mask & 0xff) };
  return smc_write("FS! ", b, 2);
}

static int tg_set(int fan, int rpm) {
  if (fan < 0 || fan >= MAX_FANS || rpm < 0 || rpm > 6000) return -1;
  if (dry) return 0;
  char k[5]; snprintf(k, sizeof k, "F%dTg", fan);
  unsigned v = (unsigned)rpm << 2;                                   // fpe2: 14.2 fixed point
  unsigned char b[2] = { (unsigned char)((v >> 8) & 0xff), (unsigned char)(v & 0xff) };
  return smc_write(k, b, 2);
}

// Back to SMC control, verified. Used on every exit path. If FS! cannot be cleared, the SMC
// still holds our forced speeds: then force every fan to its maximum instead, so a stuck forced
// mode is a loud one, never a quiet one.
static int fan_max_rpm[3] = { 2500, 5500, 2100 };   // overwritten from the config
static int tg_set(int fan, int rpm);
static int smc_auto(void) {
  for (int i = 0; i < 3; i++) { if (fs_set(0) == 0 && fs_get() == 0) return 0; usleep(50000); }
  for (int n = 0; n < 3; n++) tg_set(n, fan_max_rpm[n]);
  fs_set(7);
  return -1;
}

static double now_s(void) {
  static mach_timebase_info_data_t tb;
  if (!tb.denom) mach_timebase_info(&tb);
  return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

// ============================================================ log: RAM ring + syslog thread
#define LOG_LINES 64
#define LOG_LEN   176
static char log_ring[LOG_LINES][LOG_LEN];
static unsigned log_head, log_sent;
static pthread_mutex_t log_mx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t log_cv = PTHREAD_COND_INITIALIZER;
static int log_threaded;
static void drain_guard_log(void);

static void logf_(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logf_(const char *fmt, ...) {
  char line[LOG_LEN]; time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm);
  size_t n = strftime(line, sizeof line, "%m-%d %H:%M:%S ", &tm);
  va_list ap; va_start(ap, fmt); vsnprintf(line + n, sizeof line - n, fmt, ap); va_end(ap);
  if (!log_threaded) { syslog(LOG_NOTICE, "%s", line + n); return; }
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
    while (log_sent == log_head) {
      // wake at least every second to pass on the guard's lines
      struct timespec ts; struct timeval tv; gettimeofday(&tv, NULL);
      ts.tv_sec = tv.tv_sec + 1; ts.tv_nsec = tv.tv_usec * 1000;
      pthread_mutex_unlock(&log_mx); drain_guard_log(); pthread_mutex_lock(&log_mx);
      if (log_sent != log_head) break;
      pthread_cond_timedwait(&log_cv, &log_mx, &ts);
    }
    if (log_head - log_sent > LOG_LINES) log_sent = log_head - LOG_LINES;
    memcpy(line, log_ring[log_sent % LOG_LINES], LOG_LEN);
    log_sent++;
    pthread_mutex_unlock(&log_mx);
    syslog(LOG_NOTICE, "%s", line + 15);       // syslog adds its own time stamp
  }
  return NULL;
}

// ================================================================================= config
typedef enum { FF_NONE, FF_CPU, FF_GPU, FF_BOTH } ff_t;
typedef struct { double t; double rpm; } pt_t;
typedef struct { int sensor; int npts; pt_t pts[MAX_PTS]; } curve_t;
typedef struct { int sensor; double temp; int rpm; } floor_t;
typedef struct {
  char key[5]; double trip, warn; ff_t ff;
} sens_cfg_t;
typedef struct {
  int used; char name[8];
  int max, minrun;                // max rpm; lowest rpm the fan runs stable at (0 < x < minrun -> minrun)
  double hyst;                    // deg C: falling demand is computed at T + hyst
  double up, down;                // ramp limits, rpm per second
  int minon, minoff;              // s: once started stay on / once stopped stay off (unless warn/floor)
  double pw, fw;                  // weight of the profile shift / of the feed-forward for this fan
  int ncurves; curve_t curves[MAX_CURVES];
  int nfloors; floor_t floors[MAX_FLOORS];
} fan_cfg_t;
typedef struct { double base, vol; } prof_t;   // temperature shift: base + vol * volume
enum { P_DEFAULT, P_RUHE, P_IDLE, P_PLAYBACK, P_COUNT };
static const char *prof_name[P_COUNT] = { "default", "ruhe", "idle", "playback" };
typedef struct {
  int nsens; sens_cfg_t sens[MAX_SENS];
  fan_cfg_t fan[MAX_FANS];
  prof_t prof[P_COUNT];
  double ff_cpu, ff_gpu;          // deg C added at full load
  double gpu_full;                // PM4 commands/s that count as full GPU load
  int hdd_interval, hdd_stale, trip_hold, allow_uid;
  char reply_dir[128];
  int ok; char err[200];
} cfg_t;
static cfg_t cfg;

static int sens_index(cfg_t *c, const char *key) {
  for (int i = 0; i < c->nsens; i++) if (!strcmp(c->sens[i].key, key)) return i;
  return -1;
}

static void cfg_defaults(cfg_t *c) {
  memset(c, 0, sizeof *c);
  c->hdd_interval = 30; c->hdd_stale = 150; c->trip_hold = 300; c->allow_uid = 501;
  c->gpu_full = 3000;
  snprintf(c->reply_dir, sizeof c->reply_dir, "/Users/imac/Library/Caches/Sofa/");
  c->ok = 1;
}

static int parse_pt(const char *s, pt_t *p) {
  char *e; p->t = strtod(s, &e); if (*e != ':') return -1;
  p->rpm = strtod(e + 1, &e); if (*e) return -1;
  return (p->t >= 20 && p->t <= 110 && p->rpm >= 0 && p->rpm <= 6000) ? 0 : -1;
}

#define BAD(...) do { snprintf(c->err, sizeof c->err, "%s:%d: " __VA_ARGS__); goto bad; } while (0)
static int cfg_load(cfg_t *c, const char *path) {
  cfg_defaults(c);
  FILE *f = fopen(path, "r");
  if (!f) { snprintf(c->err, sizeof c->err, "%s: %s", path, strerror(errno)); c->ok = 0; return -1; }
  char line[1024]; int ln = 0;
  while (fgets(line, sizeof line, f)) {
    ln++;
    char *h = strchr(line, '#'); if (h) *h = 0;
    char *tok[40]; int nt = 0;
    for (char *p = strtok(line, " \t\r\n"); p && nt < 40; p = strtok(NULL, " \t\r\n")) tok[nt++] = p;
    if (!nt) continue;
    if (!strcmp(tok[0], "sensor")) {
      // sensor KEY trip T warn W [ff cpu|gpu|both|none]
      if (nt < 6 || c->nsens >= MAX_SENS || !key_ok(tok[1]) || sens_index(c, tok[1]) >= 0) BAD("bad sensor line", path, ln);
      sens_cfg_t *s = &c->sens[c->nsens];
      snprintf(s->key, sizeof s->key, "%s", tok[1]);
      for (int i = 2; i + 1 < nt; i += 2) {
        if (!strcmp(tok[i], "trip")) s->trip = atof(tok[i + 1]);
        else if (!strcmp(tok[i], "warn")) s->warn = atof(tok[i + 1]);
        else if (!strcmp(tok[i], "ff")) s->ff = !strcmp(tok[i+1], "cpu") ? FF_CPU : !strcmp(tok[i+1], "gpu") ? FF_GPU : !strcmp(tok[i+1], "both") ? FF_BOTH : FF_NONE;
        else BAD("unknown sensor option", path, ln);
      }
      if (s->trip < 30 || s->trip > 110 || s->warn < 25 || s->warn >= s->trip) BAD("sensor needs warn < trip", path, ln);
      c->nsens++;
    } else if (!strcmp(tok[0], "fan")) {
      // fan N name X max R minrun R hyst H up R/s down R/s minon S minoff S
      int n = nt >= 2 ? atoi(tok[1]) : -1;
      if (nt < 2 || n < 0 || n >= MAX_FANS || c->fan[n].used) BAD("bad fan line", path, ln);
      fan_cfg_t *fc = &c->fan[n]; fc->used = 1; fc->pw = 1; fc->fw = 1;
      for (int i = 2; i + 1 < nt; i += 2) {
        const char *k = tok[i], *v = tok[i + 1];
        if (!strcmp(k, "name")) snprintf(fc->name, sizeof fc->name, "%s", v);
        else if (!strcmp(k, "max")) fc->max = atoi(v);
        else if (!strcmp(k, "minrun")) fc->minrun = atoi(v);
        else if (!strcmp(k, "hyst")) fc->hyst = atof(v);
        else if (!strcmp(k, "up")) fc->up = atof(v);
        else if (!strcmp(k, "down")) fc->down = atof(v);
        else if (!strcmp(k, "minon")) fc->minon = atoi(v);
        else if (!strcmp(k, "minoff")) fc->minoff = atoi(v);
        else if (!strcmp(k, "profile_weight")) fc->pw = atof(v);
        else if (!strcmp(k, "ff_weight")) fc->fw = atof(v);
        else BAD("unknown fan option", path, ln);
      }
      if (fc->max < 500 || fc->max > 6000 || fc->minrun < 0 || fc->minrun > fc->max || fc->hyst < 0 || fc->hyst > 10 ||
          fc->up <= 0 || fc->down <= 0 || fc->minon < 0 || fc->minoff < 0 || fc->pw < 0 || fc->pw > 1 || fc->fw < 0 || fc->fw > 1) BAD("fan values out of range", path, ln);
    } else if (!strcmp(tok[0], "curve")) {
      // curve N KEY T:R T:R ...   (linear between points, flat outside)
      int n = nt >= 2 ? atoi(tok[1]) : -1;
      if (nt < 4 || n < 0 || n >= MAX_FANS || !c->fan[n].used) BAD("curve before its fan line", path, ln);
      fan_cfg_t *fc = &c->fan[n];
      int si = sens_index(c, tok[2]);
      if (si < 0 || fc->ncurves >= MAX_CURVES || nt - 3 > MAX_PTS) BAD("curve: unknown sensor or too many", path, ln);
      curve_t *cv = &fc->curves[fc->ncurves]; cv->sensor = si;
      for (int i = 3; i < nt; i++) {
        if (parse_pt(tok[i], &cv->pts[cv->npts])) BAD("bad point %s", path, ln, tok[i]);
        if (cv->npts && (cv->pts[cv->npts].t <= cv->pts[cv->npts-1].t || cv->pts[cv->npts].rpm < cv->pts[cv->npts-1].rpm)) BAD("points must rise", path, ln);
        if (cv->pts[cv->npts].rpm > fc->max) BAD("point above fan max", path, ln);
        cv->npts++;
      }
      fc->ncurves++;
    } else if (!strcmp(tok[0], "floor")) {
      // floor N KEY TEMP RPM : fan N runs at least RPM while KEY >= TEMP (Apple-minimum guarantee)
      int n = nt >= 2 ? atoi(tok[1]) : -1;
      if (nt != 5 || n < 0 || n >= MAX_FANS || !c->fan[n].used) BAD("bad floor line", path, ln);
      fan_cfg_t *fc = &c->fan[n];
      int si = sens_index(c, tok[2]);
      if (si < 0 || fc->nfloors >= MAX_FLOORS) BAD("floor: unknown sensor or too many", path, ln);
      floor_t *fl = &fc->floors[fc->nfloors++];
      fl->sensor = si; fl->temp = atof(tok[3]); fl->rpm = atoi(tok[4]);
      if (fl->temp < 20 || fl->temp > 110 || fl->rpm < 0 || fl->rpm > fc->max) BAD("floor out of range", path, ln);
    } else if (!strcmp(tok[0], "profile")) {
      // profile NAME SHIFT [VOLSHIFT]   positive shift = quieter (curves read as if cooler)
      int p = -1; for (int i = 0; i < P_COUNT; i++) if (nt >= 3 && !strcmp(tok[1], prof_name[i])) p = i;
      if (p < 0 || nt > 4) BAD("bad profile line", path, ln);
      c->prof[p].base = atof(tok[2]); c->prof[p].vol = nt == 4 ? atof(tok[3]) : 0;
      if (fabs(c->prof[p].base) > 8 || fabs(c->prof[p].vol) > 8) BAD("profile shift too large", path, ln);
    } else if (!strcmp(tok[0], "feedforward") && nt == 4) {
      c->ff_cpu = atof(tok[1]); c->ff_gpu = atof(tok[2]); c->gpu_full = atof(tok[3]);
      if (c->ff_cpu < 0 || c->ff_cpu > 15 || c->ff_gpu < 0 || c->ff_gpu > 15 || c->gpu_full < 1) BAD("feedforward out of range", path, ln);
    } else if (!strcmp(tok[0], "hdd_interval") && nt == 2) c->hdd_interval = atoi(tok[1]);
    else if (!strcmp(tok[0], "hdd_stale") && nt == 2) c->hdd_stale = atoi(tok[1]);
    else if (!strcmp(tok[0], "trip_hold") && nt == 2) c->trip_hold = atoi(tok[1]);
    else if (!strcmp(tok[0], "allow_uid") && nt == 2) c->allow_uid = atoi(tok[1]);
    else if (!strcmp(tok[0], "reply_dir") && nt == 2 && tok[1][0] == '/' && strlen(tok[1]) < sizeof c->reply_dir - 1 && !strstr(tok[1], ".."))
      snprintf(c->reply_dir, sizeof c->reply_dir, "%s%s", tok[1], tok[1][strlen(tok[1]) - 1] == '/' ? "" : "/");
    else BAD("unknown line", path, ln);
    continue;
  bad:
    c->ok = 0; fclose(f); return -1;
  }
  fclose(f);
  for (int n = 0; n < MAX_FANS; n++) if (c->fan[n].used) fan_max_rpm[n] = c->fan[n].max;
  if (c->hdd_interval < 5 || c->hdd_stale < 3 * c->hdd_interval || c->trip_hold < 30) { snprintf(c->err, sizeof c->err, "hdd_interval/hdd_stale/trip_hold invalid"); c->ok = 0; return -1; }
  for (int n = 0; n < MAX_FANS; n++) if (c->fan[n].used && !c->fan[n].ncurves) { snprintf(c->err, sizeof c->err, "fan %d has no curve", n); c->ok = 0; return -1; }
  if (!c->nsens) { snprintf(c->err, sizeof c->err, "no sensors"); c->ok = 0; return -1; }
  return 0;
}

static void cfg_print(FILE *o, const cfg_t *c) {
  static const char *ffn[] = { "none", "cpu", "gpu", "both" };
  for (int i = 0; i < c->nsens; i++) fprintf(o, "sensor %-4s trip %.1f warn %.1f ff %s\n", c->sens[i].key, c->sens[i].trip, c->sens[i].warn, ffn[c->sens[i].ff]);
  for (int n = 0; n < MAX_FANS; n++) if (c->fan[n].used) {
    const fan_cfg_t *f = &c->fan[n];
    fprintf(o, "fan %d %s max %d minrun %d hyst %.1f up %.0f down %.0f minon %d minoff %d profile_weight %.2f ff_weight %.2f\n", n, f->name, f->max, f->minrun, f->hyst, f->up, f->down, f->minon, f->minoff, f->pw, f->fw);
    for (int k = 0; k < f->ncurves; k++) {
      fprintf(o, "  curve %-4s", c->sens[f->curves[k].sensor].key);
      for (int i = 0; i < f->curves[k].npts; i++) fprintf(o, " %.1f:%.0f", f->curves[k].pts[i].t, f->curves[k].pts[i].rpm);
      fprintf(o, "\n");
    }
    for (int k = 0; k < f->nfloors; k++) fprintf(o, "  floor %-4s >= %.1f -> %d\n", c->sens[f->floors[k].sensor].key, f->floors[k].temp, f->floors[k].rpm);
  }
  for (int p = 0; p < P_COUNT; p++) fprintf(o, "profile %s %.1f %.1f\n", prof_name[p], c->prof[p].base, c->prof[p].vol);
  fprintf(o, "feedforward cpu %.1f gpu %.1f gpu_full %.0f\n", c->ff_cpu, c->ff_gpu, c->gpu_full);
  fprintf(o, "hdd_interval %d hdd_stale %d trip_hold %d allow_uid %d reply_dir %s\n", c->hdd_interval, c->hdd_stale, c->trip_hold, c->allow_uid, c->reply_dir);
}

// ================================================================ SMART drive temperature
// Own thread: a hanging drive blocks only this thread; the reading then goes stale and the
// controller treats the sensor as unreadable. The SMART user client is exclusive (smartctl
// fails while anyone holds it), so it is opened, read and closed every time.
static pthread_mutex_t hdd_mx = PTHREAD_MUTEX_INITIALIZER;
static double hdd_temp = -1, hdd_when = -1;

static int smart_read_once(void) {
  io_iterator_t it; io_object_t o; int r = -1, done = 0;
  if (IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IOBlockStorageDevice"), &it) != kIOReturnSuccess) return -1;
  while ((o = IOIteratorNext(it))) {
    CFTypeRef cap = IORegistryEntrySearchCFProperty(o, kIOServicePlane, CFSTR("SMART Capable"), kCFAllocatorDefault, 0);
    if (cap && !done) {
      IOCFPlugInInterface **pi = NULL; SInt32 score; IOATASMARTInterface **si = NULL;
      if (IOCreatePlugInInterfaceForService(o, kIOATASMARTUserClientTypeID, kIOCFPlugInInterfaceID, &pi, &score) == kIOReturnSuccess && pi) {
        if ((*pi)->QueryInterface(pi, CFUUIDGetUUIDBytes(kIOATASMARTInterfaceID), (LPVOID *)&si) == S_OK && si) {
          ATASMARTData d; memset(&d, 0, sizeof d);
          if ((*si)->SMARTReadData(si, &d) == kIOReturnSuccess) {
            const unsigned char *b = (const unsigned char *)&d;
            for (int i = 0; i < 30; i++) {
              const unsigned char *a = b + 2 + i * 12;
              if (a[0] == 194) { r = a[5]; break; }               // raw value, low byte = deg C
            }
          }
          (*si)->Release(si);
        }
        IODestroyPlugInInterface(pi);
        done = 1;                                                 // first SMART drive only (disk0)
      }
    }
    if (cap) CFRelease(cap);
    IOObjectRelease(o);
  }
  IOObjectRelease(it);
  return r;
}

static void *smart_thread(void *arg) {
  (void)arg;
  for (;;) {
    int t = smart_read_once();
    if (t < 0) { sleep(2); t = smart_read_once(); }          // smartctl may hold the client a moment
    if (t > 5 && t < 100) { pthread_mutex_lock(&hdd_mx); hdd_temp = t; hdd_when = now_s(); pthread_mutex_unlock(&hdd_mx); }
    sleep((unsigned)cfg.hdd_interval);
  }
  return NULL;
}

// ======================================================================= load (feed-forward)
static double cpu_load_raw(void) {                 // 0..1 over all cores since last call, NAN on error
  static unsigned long long lb, lt;
  natural_t n = 0; processor_info_array_t info = NULL; mach_msg_type_number_t cnt = 0;
  if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt) != KERN_SUCCESS || !info) return NAN;
  unsigned long long b = 0, t = 0;
  for (natural_t i = 0; i < n; i++) {
    const unsigned int *s = (const unsigned int *)&info[i * CPU_STATE_MAX];
    b += (unsigned long long)s[CPU_STATE_USER] + s[CPU_STATE_SYSTEM] + s[CPU_STATE_NICE];
    t += (unsigned long long)s[CPU_STATE_USER] + s[CPU_STATE_SYSTEM] + s[CPU_STATE_NICE] + s[CPU_STATE_IDLE];
  }
  vm_deallocate(mach_task_self(), (vm_address_t)info, cnt * sizeof(integer_t));
  double r = (lt && t > lt && b >= lb) ? (double)(b - lb) / (double)(t - lt) : NAN;
  lb = b; lt = t;
  return r;
}

static double gpu_load_raw(void) {                 // PM4 command rate / gpu_full, clamped 0..1
  static long long last = -1; static double last_t;
  io_iterator_t it; io_object_t o; long long v = -1;
  if (IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IOAccelerator"), &it) != kIOReturnSuccess) return NAN;
  while ((o = IOIteratorNext(it))) {
    CFTypeRef ps = IORegistryEntryCreateCFProperty(o, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
    if (ps && CFGetTypeID(ps) == CFDictionaryGetTypeID()) {
      CFTypeRef nr = CFDictionaryGetValue((CFDictionaryRef)ps, CFSTR("HWChannel PM4 | Commands Completed"));
      if (nr && CFGetTypeID(nr) == CFNumberGetTypeID() && v < 0) CFNumberGetValue((CFNumberRef)nr, kCFNumberLongLongType, &v);
    }
    if (ps) CFRelease(ps);
    IOObjectRelease(o);
  }
  IOObjectRelease(it);
  double t = now_s(), r = NAN;
  if (v >= 0 && last >= 0 && v >= last && t > last_t) { r = (double)(v - last) / (t - last_t) / cfg.gpu_full; if (r > 1) r = 1; }
  last = v; last_t = t;
  return r;
}

// The load samplers allocate CF objects and talk to the GPU driver: they run in their own
// thread; the control loop only takes the last values (ignored when older than 10 s).
static pthread_mutex_t load_mx = PTHREAD_MUTEX_INITIALIZER;
static double load_cpu = NAN, load_gpu = NAN, load_when = -1;
static void *load_thread(void *arg) {
  (void)arg;
  cpu_load_raw(); gpu_load_raw();
  for (;;) {
    sleep(2);
    double c = cpu_load_raw(), g = gpu_load_raw();
    pthread_mutex_lock(&load_mx); load_cpu = c; load_gpu = g; load_when = now_s(); pthread_mutex_unlock(&load_mx);
  }
  return NULL;
}

// ================================================================ state shared by threads
// Guard <-> controller page. The guard never calls syslog synchronously once the controller
// runs: it appends to glog[] and the controller's log thread passes the lines on (M4).
#define GLOG_LINES 16
typedef struct {
  volatile double beat; volatile int forced;          // controller -> guard
  volatile double trip_until; volatile int trip_max;  // survives a controller restart (N2)
  volatile int sleeping;                              // between WillSleep and HasPoweredOn (V3-2)
  volatile unsigned glog_head, glog_printed; char glog[GLOG_LINES][160];   // guard -> controller log thread
} shared_t;
static shared_t *shm;
static unsigned glog_seen;
static void drain_guard_log(void) {
  if (!shm) return;
  unsigned h = shm->glog_head;
  if (h - glog_seen > GLOG_LINES) glog_seen = h - GLOG_LINES;
  for (; glog_seen != h; glog_seen++) { char l[160]; memcpy(l, shm->glog[glog_seen % GLOG_LINES], sizeof l); l[159] = 0; syslog(LOG_ERR, "guard: %s", l); shm->glog_printed = glog_seen + 1; }
}

static void guard_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void guard_log(const char *fmt, ...) {
  char line[160]; va_list ap; va_start(ap, fmt); vsnprintf(line, sizeof line, fmt, ap); va_end(ap);
  unsigned h = shm->glog_head;
  memcpy(shm->glog[h % GLOG_LINES], line, sizeof line);
  __sync_synchronize();
  shm->glog_head = h + 1;
}

typedef struct {                // controller -> socket thread (snapshot, under pub_mx)
  int level, mode, profile; unsigned level_seq;
  double temp[MAX_SENS]; int temp_ok[MAX_SENS];
  double ac[MAX_FANS], target[MAX_FANS];
  double cpu, gpu, shift;
  char reason[96];
} pub_t;
static pub_t pub;
static pthread_mutex_t pub_mx = PTHREAD_MUTEX_INITIALIZER;

typedef struct { int ctx; double vol; double until; int pid; unsigned count; } hint_t;   // socket thread -> controller
static hint_t hint = { -1, -1, 0, 0, 0 };
static pthread_mutex_t hint_mx = PTHREAD_MUTEX_INITIALIZER;

// ============================================================================== controller
enum { M_CURVE, M_SMC, M_TRIP, M_DISABLED };
static const char *mode_name[] = { "curve", "smc", "trip", "disabled" };

static pthread_mutex_t ctl_mx = PTHREAD_MUTEX_INITIALIZER;   // control step vs. power events
static volatile int sleeping;                                // between WillSleep and HasPoweredOn
static volatile int pm_failed;                               // no sleep notifications: never force fans (V3-1)
static volatile double woke_at = -1;

static struct {
  int mode; char reason[96]; double trip_until;
  double out[MAX_FANS];            // current commanded rpm (after ramps)
  double on_since[MAX_FANS], off_since[MAX_FANS];
  double stall_since[MAX_FANS];
  double temp[MAX_SENS]; int temp_ok[MAX_SENS];
  double ac[MAX_FANS];
  double cpu_ema, gpu_ema;
  int level; int fan_count;
  double started; unsigned long locked_kb;
} st;

static double interp(const curve_t *c, double t) {
  if (t <= c->pts[0].t) return c->pts[0].rpm;
  for (int i = 1; i < c->npts; i++)
    if (t < c->pts[i].t) return c->pts[i-1].rpm + (c->pts[i].rpm - c->pts[i-1].rpm) * (t - c->pts[i-1].t) / (c->pts[i].t - c->pts[i-1].t);
  return c->pts[c->npts - 1].rpm;
}

static void set_mode(int m, const char *reason) {
  if (st.mode != m || strcmp(st.reason, reason)) logf_("-> %s (%s)", mode_name[m], reason);
  st.mode = m; snprintf(st.reason, sizeof st.reason, "%s", reason);
}

// Fault: SMC regulates, controller rests for trip_hold.
static void fault(const char *why, double now) {
  int failed = smc_auto();
  shm->forced = 0;
  char r[96]; snprintf(r, sizeof r, "%s%s", why, failed ? ", FS! RESET FAILED" : "");
  set_mode(M_TRIP, r);
  st.trip_until = now + cfg.trip_hold;
  shm->trip_max = 0; shm->trip_until = st.trip_until;
  for (int n = 0; n < MAX_FANS; n++) { st.out[n] = st.ac[n] > 0 ? st.ac[n] : 0; st.stall_since[n] = 0; }
}

static int profile_now(double now, double *vol) {
  int p = P_DEFAULT; *vol = 0;
  pthread_mutex_lock(&hint_mx);
  if (hint.ctx >= 0 && now < hint.until) { p = hint.ctx; *vol = hint.vol >= 0 ? hint.vol : 0.5; }
  pthread_mutex_unlock(&hint_mx);
  return p;
}

static void publish(int profile, double shift) {
  pthread_mutex_lock(&pub_mx);
  if (pub.level != st.level) pub.level_seq++;
  pub.level = st.level; pub.mode = st.mode; pub.profile = profile; pub.shift = shift;
  for (int i = 0; i < cfg.nsens; i++) { pub.temp[i] = st.temp[i]; pub.temp_ok[i] = st.temp_ok[i]; }
  for (int n = 0; n < MAX_FANS; n++) { pub.ac[n] = st.ac[n]; pub.target[n] = st.out[n]; }
  pub.cpu = st.cpu_ema; pub.gpu = st.gpu_ema;
  snprintf(pub.reason, sizeof pub.reason, "%s", st.reason);
  pthread_mutex_unlock(&pub_mx);
}

static void read_sensors(double now) {
  for (int i = 0; i < cfg.nsens; i++) {
    double t = NAN; int ok;
    if (!strcmp(cfg.sens[i].key, HDD_KEY)) {
      pthread_mutex_lock(&hdd_mx);
      ok = hdd_when > 0 && now - hdd_when <= cfg.hdd_stale; t = hdd_temp;
      pthread_mutex_unlock(&hdd_mx);
    } else {
      char k[5] = "    "; memcpy(k, cfg.sens[i].key, strlen(cfg.sens[i].key));
      ok = smc_temp(k, &t) == 0;
    }
    st.temp_ok[i] = ok && !isnan(t);
    st.temp[i] = st.temp_ok[i] ? t : NAN;
  }
  for (int n = 0; n < st.fan_count; n++) { char k[5]; snprintf(k, sizeof k, "F%dAc", n); if (smc_fpe2(k, &st.ac[n])) st.ac[n] = NAN; }
}

// level for Sofa: 0 normal, 1 warm (warn-5), 2 hot (warn), 3 critical (trip-2 or a trip); 2 C hysteresis down
static void update_level(void) {
  int lv = 0;
  for (int i = 0; i < cfg.nsens; i++) {
    if (!st.temp_ok[i]) continue;
    double t = st.temp[i], w = cfg.sens[i].warn, tr = cfg.sens[i].trip;
    int need = t >= tr - 2 ? 3 : t >= w ? 2 : t >= w - 5 ? 1 : 0;
    int keep = t >= tr - 4 ? 3 : t >= w - 2 ? 2 : t >= w - 7 ? 1 : 0;   // what holds the current level
    int l = need > st.level ? need : (keep >= st.level ? st.level : need);
    if (l > lv) lv = l;
  }
  if (st.mode == M_TRIP) lv = 3;
  st.level = lv;
}

static void control_step_locked(void);
static void control_step(void) {
  pthread_mutex_lock(&ctl_mx);
  if (!sleeping) control_step_locked();
  pthread_mutex_unlock(&ctl_mx);
}
static void control_step_locked(void) {
  double now = now_s();
  read_sensors(now);
  double c = NAN, g = NAN;
  pthread_mutex_lock(&load_mx); if (now - load_when < 10) { c = load_cpu; g = load_gpu; } pthread_mutex_unlock(&load_mx);
  // feed-forward smoothing: rise with tau 20 s, fall with tau 120 s (no pumping on short spikes)
  if (!isnan(c)) st.cpu_ema += (c - st.cpu_ema) * (LOOP_S / (c > st.cpu_ema ? 20.0 : 120.0));
  if (!isnan(g)) st.gpu_ema += (g - st.gpu_ema) * (LOOP_S / (g > st.gpu_ema ? 20.0 : 120.0));
  double vol; int prof = profile_now(now, &vol);
  double shift = cfg.prof[prof].base + cfg.prof[prof].vol * vol;
  update_level();

  if (st.mode == M_DISABLED) { if (fs_get() != 0) smc_auto(); publish(prof, shift); return; }
  if (pm_failed) { if (st.mode != M_SMC || fs_get() != 0) { smc_auto(); shm->forced = 0; set_mode(M_SMC, "no sleep notifications - SMC regulates"); } publish(prof, shift); return; }

  // ---- after a wake: hint and drive reading are from before the sleep (monotonic time stood
  // still), so drop them and wait for fresh values under SMC control
  if (woke_at >= 0) {
    pthread_mutex_lock(&hint_mx); hint.until = 0; pthread_mutex_unlock(&hint_mx);
    pthread_mutex_lock(&hdd_mx); double hw = hdd_when; pthread_mutex_unlock(&hdd_mx);
    if (hw < woke_at + 1) { if (st.mode != M_SMC || fs_get() != 0) { smc_auto(); shm->forced = 0; set_mode(M_SMC, "after wake, waiting for fresh sensors"); }
      for (int n = 0; n < MAX_FANS; n++) st.out[n] = isnan(st.ac[n]) ? 0 : st.ac[n];
      if (now - woke_at < cfg.hdd_stale) { publish(prof, shift); return; } }
    woke_at = -1;
  }
  // ---- faults -> SMC
  int bad = -1, over = -1;
  for (int i = 0; i < cfg.nsens; i++) {
    if (!st.temp_ok[i]) { if (bad < 0) bad = i; }
    else if (st.temp[i] >= cfg.sens[i].trip && over < 0) over = i;
  }
  pthread_mutex_lock(&hdd_mx); int hdd_never = hdd_when < 0; pthread_mutex_unlock(&hdd_mx);
  if (bad >= 0 && !strcmp(cfg.sens[bad].key, HDD_KEY) && hdd_never && now - st.started < cfg.hdd_stale) {
    if (st.mode != M_SMC || fs_get() != 0) { smc_auto(); shm->forced = 0; set_mode(M_SMC, "waiting for the first drive reading"); }
    publish(prof, shift); return;
  }
  if (st.mode == M_TRIP && now < st.trip_until) {
    // hold: either SMC (fault) or all fans at max (temperature) - re-assert, nothing else
    if (strncmp(st.reason, "limit", 5) == 0) {
      int mask = 0;
      for (int n = 0; n < st.fan_count; n++) if (cfg.fan[n].used) { if (tg_set(n, cfg.fan[n].max)) { fault("SMC write failed", now); publish(prof, shift); return; } mask |= 1 << n; }
      if (fs_set(mask) || fs_get() != mask) fault("SMC write failed", now);
      else shm->forced = mask;
    } else { if (fs_get() != 0) smc_auto(); shm->forced = 0; }
    publish(prof, shift); return;
  }
  // a healthy sensor over its trip wins over another unreadable one: max cooling (V2-9)
  if (over >= 0) {
    // temperature limit with healthy sensors: maximum cooling beats the SMC's minimum here
    char w[96]; snprintf(w, sizeof w, "limit %s %.1f >= %.1f, all fans max", cfg.sens[over].key, st.temp[over], cfg.sens[over].trip);
    set_mode(M_TRIP, w); st.trip_until = now + cfg.trip_hold;
    int mask = 0;
    for (int n = 0; n < st.fan_count; n++) if (cfg.fan[n].used) { if (tg_set(n, cfg.fan[n].max)) { fault("SMC write failed", now); publish(prof, shift); return; } mask |= 1 << n; st.out[n] = cfg.fan[n].max; }
    if (fs_set(mask) || fs_get() != mask) fault("SMC write failed", now);
    else { shm->forced = mask; shm->trip_max = 1; shm->trip_until = st.trip_until; }
    publish(prof, shift); return;
  }
  if (bad >= 0) { char w[96]; snprintf(w, sizeof w, "sensor %s unreadable", cfg.sens[bad].key); fault(w, now); publish(prof, shift); return; }
  // a trip ends only once everything is 3 C below its trip point
  if (st.mode == M_TRIP) {
    for (int i = 0; i < cfg.nsens; i++) if (st.temp[i] >= cfg.sens[i].trip - 3) { st.trip_until = now + 30; publish(prof, shift); return; }
  }

  // ---- curves
  int mask = 0;
  for (int n = 0; n < st.fan_count; n++) {
    fan_cfg_t *fc = &cfg.fan[n];
    if (!fc->used) continue;
    double up = 0, dn = 0;          // demand for rising / falling (falling read hyst C hotter)
    for (int k = 0; k < fc->ncurves; k++) {
      const curve_t *cv = &fc->curves[k];
      const sens_cfg_t *sc = &cfg.sens[cv->sensor];
      double ff = 0;
      if (sc->ff == FF_CPU || sc->ff == FF_BOTH) ff += cfg.ff_cpu * st.cpu_ema;
      if (sc->ff == FF_GPU || sc->ff == FF_BOTH) ff += cfg.ff_gpu * st.gpu_ema;
      double te = st.temp[cv->sensor] + fc->fw * ff - fc->pw * shift;
      double u = interp(cv, te), d = interp(cv, te + fc->hyst);
      if (u > up) up = u;
      if (d > dn) dn = d;
    }
    // floors: Apple-minimum guarantee etc. (independent of profile and feed-forward)
    double fl = 0;
    for (int k = 0; k < fc->nfloors; k++) if (st.temp[fc->floors[k].sensor] >= fc->floors[k].temp && fc->floors[k].rpm > fl) fl = fc->floors[k].rpm;
    if (up < fl) up = fl;
    if (dn < fl) dn = fl;
    int urgent = fl > 0;            // an active floor (Apple minimum) or a sensor at warn overrides minoff (V2-2)
    for (int k = 0; k < fc->ncurves; k++) { int s = fc->curves[k].sensor; if (st.temp[s] >= cfg.sens[s].warn) urgent = 1; }

    double cur = st.out[n], want;
    if (up > cur) want = up;                         // warmer: follow at once (ramp-limited)
    else if (dn < cur) want = dn;                    // cooler past the hysteresis: go down
    else want = cur;                                 // inside the hysteresis band: hold
    if (want > 0 && want < fc->minrun) want = fc->minrun;
    // on/off discipline (mainly the HDD fan: its start is the audible part)
    if (cur <= 0 && want > 0 && !urgent && st.off_since[n] > 0 && now - st.off_since[n] < fc->minoff) want = 0;
    if (want < fl) want = fl;       // floors hold in every case
    if (cur > 0 && want <= 0 && now - st.on_since[n] < fc->minon) want = fc->minrun > 0 ? fc->minrun : cur;
    // ramps
    double next;
    if (want > cur) next = cur <= 0 ? (want > fc->minrun ? want : fc->minrun) : (want - cur > fc->up * LOOP_S ? cur + fc->up * LOOP_S : want);
    else if (want < cur) next = (want <= 0 && cur <= (fc->minrun > 0 ? fc->minrun : 0) + 1) ? 0 : (cur - want > fc->down * LOOP_S ? cur - fc->down * LOOP_S : want);
    else next = cur;
    if (next > 0 && next < fc->minrun) next = fc->minrun;   // never inside the dead band 0 < x < minrun
    if (next > fc->max) next = fc->max;
    if (next < 0) next = 0;
    if (cur <= 0 && next > 0) { st.on_since[n] = now; st.stall_since[n] = 0; }
    if (cur > 0 && next <= 0) st.off_since[n] = now;
    st.out[n] = next;
    if (tg_set(n, (int)lround(next))) { fault("SMC write failed", now); publish(prof, shift); return; }
    mask |= 1 << n;
    // a fan told to turn must turn: after a 15 s start window, below half the target for 20 s -> fault
    if (!dry && next > 0 && now - st.on_since[n] > 15 && (isnan(st.ac[n]) || st.ac[n] < next / 2)) {
      if (st.stall_since[n] <= 0) st.stall_since[n] = now;
      else if (now - st.stall_since[n] > 20) { char w[96]; snprintf(w, sizeof w, "fan %d stalled (%.0f rpm, wanted %.0f)", n, st.ac[n], next); fault(w, now); publish(prof, shift); return; }
    } else st.stall_since[n] = 0;
  }
  if (fs_set(mask) || fs_get() != mask) { fault("SMC write failed", now); publish(prof, shift); return; }
  shm->forced = mask;
  if (st.mode != M_CURVE) set_mode(M_CURVE, "curves");
  publish(prof, shift);
}

// ============================================================================ socket thread
static int lfd_hint = -1, lfd_ctl = -1;
static unsigned hints_dropped;

// Minimal strict JSON: exactly one flat object, string/number/null/true/false values, no
// duplicate keys, nothing but whitespace after the closing brace. Fills up to 8 fields.
typedef struct { char key[12]; int type; char str[24]; double num; } jfield_t;   // type: 1 str, 2 num, 3 null, 4 bool
static const char *jws(const char *p) { while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++; return p; }
static const char *jstring(const char *p, char *out, size_t cap) {
  if (*p++ != '"') return NULL;
  size_t n = 0;
  while (*p && *p != '"') { if ((unsigned char)*p < 0x20 || *p == '\\' || n + 1 >= cap) return NULL; out[n++] = *p++; }
  if (*p != '"') return NULL;
  out[n] = 0; return p + 1;
}
static int json_parse(const char *j, jfield_t *f, int max) {
  const char *p = jws(j); int n = 0;
  if (*p++ != '{') return -1;
  p = jws(p);
  if (*p == '}') return jws(p + 1)[0] ? -1 : 0;
  for (;;) {
    if (n >= max) return -1;
    jfield_t *x = &f[n];
    if (!(p = jstring(p, x->key, sizeof x->key))) return -1;
    for (int i = 0; i < n; i++) if (!strcmp(f[i].key, x->key)) return -1;
    p = jws(p); if (*p++ != ':') return -1; p = jws(p);
    if (*p == '"') { x->type = 1; if (!(p = jstring(p, x->str, sizeof x->str))) return -1; }
    else if (!strncmp(p, "null", 4)) { x->type = 3; p += 4; }
    else if (!strncmp(p, "true", 4)) { x->type = 4; x->num = 1; p += 4; }
    else if (!strncmp(p, "false", 5)) { x->type = 4; x->num = 0; p += 5; }
    else { char *e; x->num = strtod(p, &e); if (e == p || !isfinite(x->num) || (*p != '-' && (*p < '0' || *p > '9'))) return -1; x->type = 2; p = e; }
    n++;
    p = jws(p);
    if (*p == ',') { p = jws(p + 1); continue; }
    if (*p == '}') return jws(p + 1)[0] ? -1 : n;
    return -1;
  }
}
static const jfield_t *jget(const jfield_t *f, int n, const char *key) { for (int i = 0; i < n; i++) if (!strcmp(f[i].key, key)) return &f[i]; return NULL; }

// returns profile index or -1
static int parse_hint(const char *msg, double *vol, double *ttl, int *pid) {
  jfield_t f[8]; int n = json_parse(msg, f, 8);
  if (n < 0) return -1;
  const jfield_t *v = jget(f, n, "v"), *c = jget(f, n, "ctx"), *x;
  if (!v || v->type != 2 || v->num != 1 || !c || c->type != 1) return -1;
  int p = -1;
  if (!strcmp(c->str, "ruhe")) p = P_RUHE; else if (!strcmp(c->str, "idle")) p = P_IDLE; else if (!strcmp(c->str, "playback")) p = P_PLAYBACK;
  if (p < 0) return -1;
  *vol = -1; if ((x = jget(f, n, "vol")) && x->type == 2 && x->num >= 0 && x->num <= 1) *vol = x->num;
  *ttl = 90; if ((x = jget(f, n, "ttl")) && x->type == 2) *ttl = x->num < 10 ? 10 : x->num > 300 ? 300 : x->num;
  *pid = 0; if ((x = jget(f, n, "pid")) && x->type == 2 && x->num > 0 && x->num < 1e7) *pid = (int)x->num;
  return p;
}

// sender must be a socket owned by allow_uid directly below reply_dir, no symlinks
static struct { char path[104]; double checked; int ok; } reply_cache;
static int reply_ok(const struct sockaddr_un *sa, socklen_t len) {
  if (len <= (socklen_t)offsetof(struct sockaddr_un, sun_path) || sa->sun_family != AF_UNIX) return 0;
  char path[105]; size_t n = (size_t)len - offsetof(struct sockaddr_un, sun_path);
  if (n > sizeof sa->sun_path) n = sizeof sa->sun_path;
  memcpy(path, sa->sun_path, n); path[n] = 0;
  size_t dl = strlen(cfg.reply_dir);
  if (strncmp(path, cfg.reply_dir, dl) || strchr(path + dl, '/') || !path[dl] || strstr(path, "..")) return 0;
  double now = now_s();
  if (reply_cache.ok && !strcmp(reply_cache.path, path) && now - reply_cache.checked < 30) return 1;
  // lstat may touch the disk; this thread may block, the control loop does not care
  struct stat sd, sf; char dir[128]; snprintf(dir, sizeof dir, "%.*s", (int)(dl - 1), cfg.reply_dir);
  // only uid allow_uid (or root) can bind a socket in a directory it owns that nobody else may
  // write: a valid sender address therefore authenticates the sender (datagrams carry no creds)
  int ok = lstat(dir, &sd) == 0 && S_ISDIR(sd.st_mode) && (int)sd.st_uid == cfg.allow_uid && (sd.st_mode & 022) == 0 &&
           lstat(path, &sf) == 0 && S_ISSOCK(sf.st_mode) && (int)sf.st_uid == cfg.allow_uid;
  snprintf(reply_cache.path, sizeof reply_cache.path, "%s", path); reply_cache.checked = now; reply_cache.ok = ok;
  return ok;
}

static int state_json(char *b, size_t cap) {
  static const char *names[MAX_FANS] = { "ODD", "HDD", "CPU" };
  pub_t p; pthread_mutex_lock(&pub_mx); p = pub; pthread_mutex_unlock(&pub_mx);
  int ic = sens_index(&cfg, "TC0P"), ig = sens_index(&cfg, "TG0D"), ih = sens_index(&cfg, HDD_KEY), ip = sens_index(&cfg, "Tp2H"), ia = sens_index(&cfg, "TA0P");
  #define TV(i) ((i) >= 0 && p.temp_ok[i] ? p.temp[i] : -1.0)
  int n = snprintf(b, cap, "{\"v\":1,\"level\":%d,\"mode\":\"%s\",\"cpu_c\":%.1f,\"gpu_c\":%.1f,\"hdd_c\":%.1f,\"psu_c\":%.1f,\"amb_c\":%.1f,\"fans\":[",
                   p.level, p.mode == M_CURVE ? "curve" : p.mode == M_TRIP ? "trip" : "smc", TV(ic), TV(ig), TV(ih), TV(ip), TV(ia));
  #undef TV
  for (int f = 0; f < MAX_FANS && n > 0 && (size_t)n < cap; f++)
    n += snprintf(b + n, cap - (size_t)n, "%s{\"name\":\"%s\",\"rpm\":%.0f}", f ? "," : "", names[f], isnan(p.ac[f]) ? -1.0 : p.ac[f]);
  if (n > 0 && (size_t)n < cap) n += snprintf(b + n, cap - (size_t)n, "]}\n");
  return n > 0 && (size_t)n < cap ? n : -1;
}

static int status_text(char *buf, size_t cap) {
  static const char *ffn[] = { "", " ff=cpu", " ff=gpu", " ff=cpu+gpu" };
  pub_t p; pthread_mutex_lock(&pub_mx); p = pub; pthread_mutex_unlock(&pub_mx);
  hint_t h; pthread_mutex_lock(&hint_mx); h = hint; pthread_mutex_unlock(&hint_mx);
  double now = now_s(); size_t o = 0;
  #define OUT(...) do { int _n = snprintf(buf + o, o < cap ? cap - o : 0, __VA_ARGS__); if (_n > 0) o += (size_t)_n; if (o >= cap) o = cap - 1; } while (0)
  OUT("mode %s (%s)%s\nlevel %d\n", mode_name[p.mode], p.reason, dry ? " DRY RUN - SMC untouched" : "", p.level);
  OUT("profile %s shift %+.1f", prof_name[p.profile], p.shift);
  if (h.ctx >= 0 && now < h.until) OUT(" (hint %.0f s left, vol %.2f, pid %d)", h.until - now, h.vol, h.pid);
  OUT("\nhints_received %u dropped %u\nload cpu %.2f gpu %.2f\n", h.count, hints_dropped, p.cpu, p.gpu);
  for (int n = 0; n < MAX_FANS; n++) if (cfg.fan[n].used) OUT("fan %d %-4s actual %5.0f target %5.0f\n", n, cfg.fan[n].name, p.ac[n], p.target[n]);
  for (int i = 0; i < cfg.nsens; i++) {
    if (p.temp_ok[i]) OUT("temp %-4s %5.1f warn %.0f trip %.0f%s\n", cfg.sens[i].key, p.temp[i], cfg.sens[i].warn, cfg.sens[i].trip, ffn[cfg.sens[i].ff]);
    else OUT("temp %-4s  n/a  warn %.0f trip %.0f\n", cfg.sens[i].key, cfg.sens[i].warn, cfg.sens[i].trip);
  }
  if (sleeping) OUT("sleeping yes (FS!=0, controller paused)\n");
  OUT("memlock %lu KB\nuptime %.0f\n", st.locked_kb, now - st.started);
  pthread_mutex_lock(&log_mx);
  unsigned from = log_head > 15 ? log_head - 15 : 0;
  for (unsigned i = from; i < log_head; i++) OUT("log %s\n", log_ring[i % LOG_LINES]);
  pthread_mutex_unlock(&log_mx);
  OUT(".\n");
  #undef OUT
  return (int)o;
}

static void take_hint(const char *msg, const struct sockaddr_un *from, socklen_t flen, int *have_peer, struct sockaddr_un *peer, socklen_t *plen) {
  double vol, ttl; int pid;
  if (from && !reply_ok(from, flen)) { hints_dropped++; return; }    // unauthenticated sender (V2-1)
  int p = parse_hint(msg, &vol, &ttl, &pid);
  if (p < 0) { hints_dropped++; return; }
  double now = now_s();
  pthread_mutex_lock(&hint_mx);
  int changed = hint.ctx != p || now >= hint.until;
  hint.ctx = p; hint.vol = vol; hint.until = now + ttl; hint.pid = pid; hint.count++;
  pthread_mutex_unlock(&hint_mx);
  static double last_log = -100;
  if (changed && now - last_log >= 10) { last_log = now; logf_("context %s (vol %.2f, ttl %.0f, pid %d)", prof_name[p], vol, ttl, pid); }
  if (from) {
    char b[1024]; int n = state_json(b, sizeof b);
    if (n > 0) sendto(lfd_hint, b, (size_t)n, MSG_DONTWAIT, (const struct sockaddr *)from, flen);
    memcpy(peer, from, sizeof *peer); *plen = flen; *have_peer = 1;
  }
}

static void power_sleep(void);
static void power_wake(void);
static void *socket_thread(void *arg) {
  (void)arg;
  // This thread runs with uid allow_uid: lstat and sendto are then checked by the kernel with
  // the user's rights, so a symlink swapped in after the check cannot make root write anywhere.
  if (pthread_setugid_np((uid_t)cfg.allow_uid, (gid_t)20)) logf_("socket thread keeps root credentials (setugid failed)");
  struct sockaddr_un peer; socklen_t plen = 0; int have_peer = 0; unsigned seen_seq = 0;
  for (;;) {
    struct pollfd p[2] = { { lfd_hint, POLLIN, 0 }, { lfd_ctl, POLLIN, 0 } };
    int r = poll(p, 2, 1000);
    if (r > 0 && (p[0].revents & POLLIN)) {
      char msg[HINT_MAX + 1]; struct sockaddr_un from; socklen_t fl = sizeof from;
      ssize_t n = recvfrom(lfd_hint, msg, HINT_MAX, MSG_DONTWAIT, (struct sockaddr *)&from, &fl);
      if (n > 0) { msg[n] = 0; take_hint(msg, &from, fl, &have_peer, &peer, &plen); }
    }
    if (r > 0 && (p[1].revents & POLLIN)) {
      int fd = accept(lfd_ctl, NULL, NULL);
      if (fd >= 0) {
        struct timeval tv = { 0, 300000 }; int on = 1;
        int fl = fcntl(fd, F_GETFL); if (fl >= 0) fcntl(fd, F_SETFL, fl & ~O_NONBLOCK);   // timeouts, not EAGAIN (M1)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
        char cmd[HINT_MAX + 1]; ssize_t n = 0;
        double deadline = now_s() + 0.5;                       // whole request within 500 ms (V3-3)
        while (n < HINT_MAX) {
          double left = deadline - now_s(); if (left <= 0) { n = 0; break; }
          struct pollfd pf = { fd, POLLIN, 0 };
          if (poll(&pf, 1, (int)(left * 1000) + 1) <= 0) { n = 0; break; }
          ssize_t k = read(fd, cmd + n, (size_t)(HINT_MAX - n)); if (k <= 0) break;
          n += k; if (memchr(cmd, '\n', (size_t)n)) break;
        }
        if (n > 0) {
          cmd[n] = 0; char *nl = strchr(cmd, '\n'); if (nl) *nl = 0;
          static char out[8192]; int len = 0;
          uid_t uid = (uid_t)-1; gid_t gid; if (getpeereid(fd, &uid, &gid)) uid = (uid_t)-1;
          if (!strcmp(cmd, "STATUS")) len = status_text(out, sizeof out);
          else if (!strcmp(cmd, "STATE")) len = state_json(out, sizeof out);
          else if (!strncmp(cmd, "HINT ", 5) && (uid == 0 || (int)uid == cfg.allow_uid)) { take_hint(cmd + 5, NULL, 0, &have_peer, &peer, &plen); len = snprintf(out, sizeof out, "OK\n"); }
          else if (!strcmp(cmd, "SIMSLEEP") && uid == 0) { power_sleep(); len = snprintf(out, sizeof out, "OK slept (FS!=0x%x)\n", fs_get()); }
          else if (!strcmp(cmd, "SIMWAKE") && uid == 0) { power_wake(); len = snprintf(out, sizeof out, "OK woke\n"); }
          else len = snprintf(out, sizeof out, "ERR\n");
          if (len > 0) { ssize_t w = write(fd, out, (size_t)len); (void)w; }
        }
        close(fd);
      }
    }
    // push the state on every level change to the last valid Sofa address
    unsigned seq; pthread_mutex_lock(&pub_mx); seq = pub.level_seq; pthread_mutex_unlock(&pub_mx);
    if (seq != seen_seq) {
      seen_seq = seq;
      if (have_peer) { char b[1024]; int n = state_json(b, sizeof b); if (n > 0) sendto(lfd_hint, b, (size_t)n, MSG_DONTWAIT, (struct sockaddr *)&peer, plen); }
    }
  }
  return NULL;
}

// ============================================================================ sleep / wake
// Before the system sleeps the SMC gets the fans back (FS! = 0) and the controller pauses; after
// the wake it takes over again only with fresh sensor values. A hang during sleep/wake therefore
// leaves the fans under SMC control, never forced.
static io_connect_t pm_root;
static void power_sleep(void) {
  pthread_mutex_lock(&ctl_mx);
  sleeping = 1; shm->sleeping = 1;
  int failed = smc_auto(); shm->forced = 0;
  pthread_mutex_unlock(&ctl_mx);
  logf_("system sleep: FS!=0%s", failed ? " FAILED" : "");
}
static void power_wake(void) {
  pthread_mutex_lock(&ctl_mx);
  woke_at = now_s(); sleeping = 0; shm->sleeping = 0;
  pthread_mutex_unlock(&ctl_mx);
  logf_("system woke: waiting for fresh sensors");
}
static void power_cb(void *ref, io_service_t svc, natural_t type, void *arg) {
  (void)ref; (void)svc;
  switch (type) {
    case kIOMessageCanSystemSleep: IOAllowPowerChange(pm_root, (long)arg); break;
    case kIOMessageSystemWillSleep: power_sleep(); IOAllowPowerChange(pm_root, (long)arg); break;
    case kIOMessageSystemWillPowerOn: break;
    case kIOMessageSystemHasPoweredOn: power_wake(); break;
    default: break;
  }
}
static void *power_thread(void *arg) {
  (void)arg;
  IONotificationPortRef port = NULL; io_object_t notifier;
  pm_root = IORegisterForSystemPower(NULL, &port, power_cb, &notifier);
  if (!pm_root || !port) { pm_failed = 1; logf_("IORegisterForSystemPower failed - sleep cannot be handled, fans stay under SMC control"); return NULL; }
  CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(port), kCFRunLoopCommonModes);
  CFRunLoopRun();
  return NULL;
}

// ============================================================================ process glue
static void ctl_crash(int sig) {
  // async-signal-safe enough: two IOConnectCallStructMethod calls (Mach messages), then _exit
  fs_set(0); fs_set(0);
  _exit(128 + sig);
}
static volatile sig_atomic_t ctl_stop;
static void ctl_term(int sig) { (void)sig; ctl_stop = 1; }

static void lock_memory(void) {
  // mlockall is declared on Darwin but not implemented (returns an error on 10.9); then wire every
  // loaded image's segments so no code page we run must come back from the (possibly vanished)
  // boot disk. Stacks: prefault_stack(); heap: small and hot, not wired.
  if (mlockall(MCL_CURRENT | MCL_FUTURE) == 0) { st.locked_kb = (unsigned long)-1; return; }
  unsigned long kb = 0;
  for (uint32_t i = 0; i < _dyld_image_count(); i++) {
    const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
    if (!mh || mh->magic != MH_MAGIC_64) continue;
    intptr_t slide = _dyld_get_image_vmaddr_slide(i);
    const struct load_command *lc = (const struct load_command *)(mh + 1);
    for (uint32_t j = 0; j < mh->ncmds; j++, lc = (const struct load_command *)((const char *)lc + lc->cmdsize)) {
      if (lc->cmd != LC_SEGMENT_64) continue;
      const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
      if (!strcmp(sg->segname, "__PAGEZERO") || !strcmp(sg->segname, "__LINKEDIT") || !sg->vmsize) continue;
      if (mlock((void *)(uintptr_t)(sg->vmaddr + (uint64_t)slide), (size_t)sg->vmsize) == 0) kb += (unsigned long)(sg->vmsize / 1024);
    }
  }
  st.locked_kb = kb;
}

static void ctl_atexit(void) { smc_auto(); }

static void prefault_stack(void) {
  // touch and wire 256 KB of this thread's stack below the current frame (M2)
  volatile char buf[256 * 1024];
  for (size_t i = 0; i < sizeof buf; i += 4096) buf[i] = 0;
  mlock((const void *)buf, sizeof buf);
}

static int spawn(void *(*fn)(void *)) {
  // own stack, wired, so a vanished swap/boot disk cannot stall a helper thread on a page-in (V3-4)
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

static void controller(void) {
  pid_t guard = getppid();
  static char altstack[64 * 1024];
  stack_t ss = { .ss_sp = altstack, .ss_size = sizeof altstack, .ss_flags = 0 };
  sigaltstack(&ss, NULL);                                          // crash handler works on stack overflow (N9)
  struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = ctl_crash; sa.sa_flags = SA_ONSTACK;
  sigaction(SIGSEGV, &sa, NULL); sigaction(SIGBUS, &sa, NULL); sigaction(SIGILL, &sa, NULL); sigaction(SIGFPE, &sa, NULL); sigaction(SIGABRT, &sa, NULL);
  signal(SIGTERM, ctl_term); signal(SIGINT, ctl_term); signal(SIGHUP, SIG_IGN); signal(SIGPIPE, SIG_IGN);
  if (smc_open()) { syslog(LOG_ERR, "controller: AppleSMC not reachable"); _exit(1); }
  smc_auto();
  atexit(ctl_atexit);
  st.started = now_s();
  unsigned char b[32]; UInt32 sz, ty;
  st.fan_count = smc_read("FNum", b, &sz, &ty) == 0 && sz == 1 ? b[0] : 0;
  if (st.fan_count > MAX_FANS) st.fan_count = MAX_FANS;
  for (int n = 0; n < MAX_FANS; n++) { st.out[n] = 0; char k[5]; snprintf(k, sizeof k, "F%dAc", n); double a; if (n < st.fan_count && smc_fpe2(k, &a) == 0) st.out[n] = a; st.on_since[n] = st.started - 3600; st.off_since[n] = 0; }
  st.mode = M_SMC; snprintf(st.reason, sizeof st.reason, "start");
  sleeping = shm->sleeping;                                        // restarted between WillSleep and wake (V3-2)
  glog_seen = shm->glog_printed;                                   // only what no controller printed yet (V3-5)
  if (shm->trip_until > st.started) {                              // a trip outlives a controller restart (N2)
    st.mode = M_TRIP; st.trip_until = shm->trip_until;
    snprintf(st.reason, sizeof st.reason, shm->trip_max ? "limit (inherited), all fans max" : "fault (inherited)");
  }
  if (!cfg.ok) { st.mode = M_DISABLED; snprintf(st.reason, sizeof st.reason, "config: %.80s", cfg.err); }
  log_threaded = 1;
  if (spawn(log_thread)) { log_threaded = 0; }
  if (spawn(smart_thread)) { syslog(LOG_ERR, "no SMART thread"); }
  if (spawn(socket_thread)) { syslog(LOG_ERR, "no socket thread"); }
  if (spawn(load_thread)) { syslog(LOG_ERR, "no load thread"); }
  if (spawn(power_thread)) { syslog(LOG_ERR, "no power thread"); }
  lock_memory();
  prefault_stack();
  logf_("controller up (pid %d, %d fans, %lu KB wired)%s%s", getpid(), st.fan_count, st.locked_kb, cfg.ok ? "" : ", DISABLED: ", cfg.ok ? "" : cfg.err);
  double next = now_s();
  while (!ctl_stop) {
    if (getppid() != guard) { logf_("guard gone - stopping, FS!=0"); break; }   // launchd starts a new guard (N1)
    double t = now_s();
    if (t >= next) { control_step(); shm->beat = now_s(); next = t + LOOP_S; }
    double wait = next - now_s();
    if (wait > 0) usleep((useconds_t)(wait * 1e6 > 500000 ? 500000 : wait * 1e6));
  }
  smc_auto(); shm->forced = 0;
  logf_("controller stopped, FS!=0");
  usleep(200000);
  _exit(0);
}

static volatile sig_atomic_t guard_stop;
static void guard_term(int sig) { (void)sig; guard_stop = 1; }

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

static int run_daemon(const char *conf) {
  openlog("sofa-fand", LOG_PID, LOG_DAEMON);
  // 1. safety first: whatever a previous instance left behind, the SMC regulates again
  if (smc_open()) { syslog(LOG_ERR, "AppleSMC not reachable"); return 1; }
  if (smc_auto()) syslog(LOG_ERR, "FS! reset failed at start");
  // 2. config once, never again
  cfg_load(&cfg, conf);
  if (!cfg.ok) syslog(LOG_ERR, "config: %s - fans stay under SMC control", cfg.err);
  // 3. sockets (bound by the guard, inherited by every controller)
  struct stat sd;
  if (lstat(RUN_DIR, &sd) == 0 && (!S_ISDIR(sd.st_mode) || sd.st_uid != 0)) { syslog(LOG_ERR, "%s is not a root directory, refusing", RUN_DIR); return 1; }
  if (mkdir(RUN_DIR, 0755) && errno != EEXIST) { syslog(LOG_ERR, "mkdir %s: %m", RUN_DIR); return 1; }
  chmod(RUN_DIR, 0755);
  unlink("/var/run/sofa-fand.sock");                                 // v1 leftover
  lfd_hint = bind_sock(HINT_SOCK, SOCK_DGRAM, 0666);
  lfd_ctl = bind_sock(CTL_SOCK, SOCK_STREAM, 0666);
  if (lfd_hint < 0 || lfd_ctl < 0) syslog(LOG_ERR, "sockets unavailable: %m - no hints, no status (fans still regulated)");
  shm = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
  if (shm == MAP_FAILED) { syslog(LOG_ERR, "mmap failed"); return 1; }
  mlock(shm, 4096);
  signal(SIGTERM, guard_term); signal(SIGINT, guard_term); signal(SIGHUP, SIG_IGN); signal(SIGPIPE, SIG_IGN);
  lock_memory();
  prefault_stack();
  syslog(LOG_NOTICE, "guard up (pid %d)%s", getpid(), dry ? " DRY RUN" : "");
  int restarts = 0; double window = now_s();
  while (!guard_stop) {
    shm->beat = now_s(); shm->forced = 0;
    pid_t child = fork();
    if (child == 0) controller();
    if (child < 0) { smc_auto(); sleep(5); continue; }
    while (!guard_stop) {
      int stv = 0; pid_t r = waitpid(child, &stv, WNOHANG);
      if (r == child || (r < 0 && errno == ECHILD)) {
        int failed = smc_auto();                         // controller gone: SMC first, then talk
        guard_log("controller %d ended (%s %d), FS!=0%s", child, WIFSIGNALED(stv) ? "signal" : "exit",
               WIFSIGNALED(stv) ? WTERMSIG(stv) : WEXITSTATUS(stv), failed ? " FAILED" : "");
        break;
      }
      if (now_s() - shm->beat > GUARD_STALE) {
        smc_auto(); kill(child, SIGKILL); waitpid(child, &stv, 0); smc_auto();
        guard_log("controller %d hung (no heartbeat %.0f s), killed, FS!=0", child, GUARD_STALE);
        break;
      }
      // belt and braces: FS! set while the controller says it forces nothing
      if (!dry && shm->forced == 0 && fs_get() > 0) { usleep(300000); if (shm->forced == 0 && fs_get() > 0) { smc_auto(); guard_log("FS! set without controller request, reset"); } }
      usleep(500000);
    }
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
  unlink(HINT_SOCK); unlink(CTL_SOCK);
  syslog(LOG_NOTICE, "guard stopped, FS!=0 (0x%x)", fs_get());
  return 0;
}

// ================================================================================ client
static int ctl_client(const char *cmd) {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return 1;
  struct sockaddr_un sa; memset(&sa, 0, sizeof sa); sa.sun_family = AF_UNIX;
  snprintf(sa.sun_path, sizeof sa.sun_path, "%s", CTL_SOCK);
  struct timeval tv = { 3, 0 };
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
  if (connect(fd, (struct sockaddr *)&sa, sizeof sa)) { fprintf(stderr, "sofa-fand not reachable (%s)\n", CTL_SOCK); close(fd); return 1; }
  char line[600]; int n = snprintf(line, sizeof line, "%s\n", cmd);
  if (n <= 0 || n >= (int)sizeof line || write(fd, line, (size_t)n) != n) { close(fd); return 1; }
  char buf[4096]; ssize_t r; int err = 0;
  while ((r = read(fd, buf, sizeof buf)) > 0) { fwrite(buf, 1, (size_t)r, stdout); if (!strncmp(buf, "ERR", 3)) err = 1; }
  close(fd);
  return err;
}

int main(int argc, char **argv) {
  const char *conf = CONF_PATH;
  for (int i = 2; i + 1 < argc; i++) if (!strcmp(argv[i], "-c")) conf = argv[i + 1];
  for (int i = 2; i < argc; i++) if (!strcmp(argv[i], "-n")) dry = 1;
  if (argc >= 2 && !strcmp(argv[1], "run")) return run_daemon(conf);
  if (argc >= 2 && !strcmp(argv[1], "check")) {
    if (cfg_load(&cfg, conf)) { fprintf(stderr, "%s\n", cfg.err); return 1; }
    cfg_print(stdout, &cfg); return 0;
  }
  if (argc == 2 && !strcmp(argv[1], "status")) return ctl_client("STATUS");
  if (argc == 2 && !strcmp(argv[1], "state")) return ctl_client("STATE");
  if (argc >= 3 && argc <= 5 && !strcmp(argv[1], "hint")) {
    char c[300];
    snprintf(c, sizeof c, "HINT {\"v\":1,\"ctx\":\"%.16s\",\"vol\":%s,\"ttl\":%d,\"pid\":%d}", argv[2], argc >= 4 ? argv[3] : "null", argc >= 5 ? atoi(argv[4]) : 90, getpid());
    return ctl_client(c);
  }
  if (argc == 2 && !strcmp(argv[1], "reset")) {
    if (smc_open() || smc_auto()) { fprintf(stderr, "FS! reset failed (root?)\n"); return 1; }
    printf("FS! = 0x%x (SMC regulates)\n", fs_get()); return 0;
  }
  fprintf(stderr, "usage: sofa-fand run [-c CONF] [-n] | status | state | hint CTX [VOL] [TTL] | reset | check [-c CONF]\n");
  return 2;
}
