// sofa-fanlearn - passive data collector for the self-optimisation of sofa-fand (issue #2, stage 1)
//
// Reads, never writes: temperatures, fan speeds and power straight from the SMC (read-only key
// reads, no root needed), context/profile/load/drive temperature from sofa-fand's ctl socket.
// The sensor list comes from sofa-fand's STATUS (its config), so nothing is hard-wired to one iMac.
// Samples are kept in memory and appended to one CSV per day only every few hours (the HDD should
// rest), on SIGTERM/SIGINT/SIGHUP and when the buffer is large. The model is fitted on this data.
//
//   sofa-fanlearn log [-o dir] [-f flush_s]   collect (LaunchDaemon, runs as the user)
//   sofa-fanlearn once                        print the header and one sample, then exit
//
// Sampling: 10 s while a fan runs or the CPU is busy, 20 s when everything is calm (each SMC
// transaction costs ~25 kernel wakeups on this machine, see sofa-fand.c).
#include <IOKit/IOKitLib.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <dirent.h>
#include <time.h>
#include <unistd.h>

#define CTL_SOCK  "/var/run/sofa-fand/ctl.sock"
#define MAX_SENS  32
#define MAX_FANS  6
#define DT_BUSY   10
#define DT_CALM   20
#define BUF_MAX   (2 * 1024 * 1024)
#define KEEP_DAYS 60

// ------------------------------------------------------------------------------ SMC (read only)
typedef struct { char major, minor, build, reserved[1]; UInt16 release; } smc_vers_t;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } smc_plimit_t;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } smc_keyinfo_t;
typedef struct {
  UInt32 key; smc_vers_t vers; smc_plimit_t pLimitData; smc_keyinfo_t keyInfo;
  char result; char status; char data8; UInt32 data32; unsigned char bytes[32];
} smc_data_t;
static io_connect_t smc;
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
#define KCACHE 64
static struct { UInt32 key, size, type; } kcache[KCACHE];
static int kcache_n;
// only the read commands 9 (key info) and 5 (read bytes) are ever sent
static int smc_read(const char *key4, unsigned char *buf, UInt32 *size, UInt32 *type) {
  UInt32 k = k2u(key4); smc_data_t in, out; int c = -1;
  for (int i = 0; i < kcache_n; i++) if (kcache[i].key == k) { c = i; break; }
  if (c < 0) {
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = k; in.data8 = 9;
    int miss = smc_call(&in, &out) || out.result;     // missing keys are cached too (size 0)
    if (kcache_n >= KCACHE) kcache_n = 0;              // sensor list changed a lot: start over
    c = kcache_n++; kcache[c].key = k;
    kcache[c].size = miss ? 0 : out.keyInfo.dataSize; kcache[c].type = miss ? 0 : out.keyInfo.dataType;
  }
  if (kcache[c].size == 0 || kcache[c].size > 32) return -1;
  memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
  in.key = k; in.keyInfo.dataSize = kcache[c].size; in.data8 = 5;
  if (smc_call(&in, &out) || out.result) return -1;
  *size = kcache[c].size; *type = kcache[c].type; memcpy(buf, out.bytes, *size);
  return 0;
}
static void key4(const char *s, char k[5]) { memcpy(k, "    ", 5); memcpy(k, s, strnlen(s, 4)); }
static double smc_temp(const char *key) {          // sp78, NAN if unreadable or implausible
  char k[5]; key4(key, k); unsigned char b[32]; UInt32 sz, ty;
  if (smc_read(k, b, &sz, &ty) || ty != k2u("sp78") || sz != 2) return NAN;
  double v = (signed char)b[0] + b[1] / 256.0;
  return v >= 0 && v <= 130 ? v : NAN;
}
static double smc_fpe2(const char *key) {
  char k[5]; key4(key, k); unsigned char b[32]; UInt32 sz, ty;
  if (smc_read(k, b, &sz, &ty) || ty != k2u("fpe2") || sz != 2) return NAN;
  return ((b[0] << 8) | b[1]) / 4.0;
}
static double smc_watts(const char *key) {         // sp96: int16 / 64 = W (PCPL = 65.00 W = TDP)
  char k[5]; key4(key, k); unsigned char b[32]; UInt32 sz, ty;
  if (smc_read(k, b, &sz, &ty) || ty != k2u("sp96") || sz != 2) return NAN;
  return (double)(int16_t)((b[0] << 8) | b[1]) / 64.0;
}
static int smc_int(const char *key) {             // ui8 / ui16, -1 if unreadable
  char k[5]; key4(key, k); unsigned char b[32]; UInt32 sz, ty;
  if (smc_read(k, b, &sz, &ty)) return -1;
  if (sz == 1) return b[0];
  if (sz == 2) return (b[0] << 8) | b[1];
  return -1;
}

// ------------------------------------------------------------------------- sofa-fand status
typedef struct {
  int ok; char mode[12], profile[12]; double shift, cpu, gpu, hdd;
  int nsens; char sens[MAX_SENS][5];
} fand_t;
static int fand_status(fand_t *f) {
  memset(f, 0, sizeof *f); f->shift = f->cpu = f->gpu = f->hdd = NAN;
  snprintf(f->mode, sizeof f->mode, "-"); snprintf(f->profile, sizeof f->profile, "-");
  int fd = socket(AF_UNIX, SOCK_STREAM, 0); if (fd < 0) return -1;
  struct timeval tv = { 1, 0 };
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv); setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
  int on = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
  struct sockaddr_un sa; memset(&sa, 0, sizeof sa); sa.sun_family = AF_UNIX; snprintf(sa.sun_path, sizeof sa.sun_path, "%s", CTL_SOCK);
  char buf[8192]; size_t n = 0;
  if (connect(fd, (struct sockaddr *)&sa, sizeof sa) || write(fd, "STATUS\n", 7) != 7) { close(fd); return -1; }
  for (;;) { ssize_t k = read(fd, buf + n, sizeof buf - 1 - n); if (k <= 0) break; n += (size_t)k; if (n >= sizeof buf - 1) break; }
  close(fd); buf[n] = 0;
  if (!strstr(buf, "\n.\n")) return -1;                 // incomplete answer
  for (char *l = strtok(buf, "\n"); l; l = strtok(NULL, "\n")) {
    char a[16], b[16]; double x, y;
    if (sscanf(l, "mode %11s", a) == 1) snprintf(f->mode, sizeof f->mode, "%s", a);
    else if (sscanf(l, "profile %11s shift %lf", a, &x) == 2) { snprintf(f->profile, sizeof f->profile, "%s", a); f->shift = x; }
    else if (sscanf(l, "load cpu %lf gpu %lf", &x, &y) == 2) { f->cpu = x; f->gpu = y; }
    else if (sscanf(l, "temp %4s %15s", a, b) == 2) {
      if (!strcmp(a, "HDD")) f->hdd = strcmp(b, "n/a") ? atof(b) : NAN;
      else if (f->nsens < MAX_SENS) snprintf(f->sens[f->nsens++], 5, "%s", a);
    }
  }
  f->ok = 1; return 0;
}

// ------------------------------------------------------------------------------------ buffer
static char *buf; static size_t blen;
static char outdir[512];
static char cur_day[16];
static char header[2048], last_header[2048];
static volatile sig_atomic_t stop, flush_now;
static void on_sig(int s) { if (s == SIGHUP) flush_now = 1; else stop = 1; }

static void bappend(const char *s) {
  size_t n = strlen(s);
  if (blen + n + 1 > BUF_MAX) return;                    // flush() runs before this can happen
  memcpy(buf + blen, s, n); blen += n; buf[blen] = 0;
}
static void prune(void) {                                // drop day files older than KEEP_DAYS
  DIR *d = opendir(outdir); if (!d) return;
  time_t lim = time(NULL) - KEEP_DAYS * 86400; struct dirent *e;
  while ((e = readdir(d))) {
    int y, m, dd; char tail[8]; const char *nm = e->d_name;
    if (strlen(nm) != 14) continue;
    int digits = 1; for (int i = 0; i < 10; i++) if (i != 4 && i != 7 && (nm[i] < '0' || nm[i] > '9')) digits = 0;
    if (!digits || nm[4] != '-' || nm[7] != '-') continue;
    if (sscanf(e->d_name, "%4d-%2d-%2d.%7s", &y, &m, &dd, tail) != 4 || strcmp(tail, "csv")) continue;
    struct tm t; memset(&t, 0, sizeof t); t.tm_year = y - 1900; t.tm_mon = m - 1; t.tm_mday = dd; t.tm_hour = 12;
    if (mktime(&t) < lim) { char p[800]; snprintf(p, sizeof p, "%s/%s", outdir, e->d_name); unlink(p); }
  }
  closedir(d);
}
static int flush_buf(void) {
  if (!blen) return 0;
  char p[600]; snprintf(p, sizeof p, "%s/%s.csv", outdir, cur_day);
  int fd = open(p, O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (fd < 0) { fprintf(stderr, "sofa-fanlearn: open %s: %s\n", p, strerror(errno)); return -1; }
  off_t start = lseek(fd, 0, SEEK_END);
  size_t o = 0;
  while (o < blen) {
    ssize_t w = write(fd, buf + o, blen - o);
    if (w < 0 && errno == EINTR) continue;
    if (w <= 0) break;
    o += (size_t)w;
  }
  if (o < blen) {                                      // keep the buffer, cut the torn tail off
    if (start >= 0 && ftruncate(fd, start)) {}
    close(fd); fprintf(stderr, "sofa-fanlearn: short write %s: %s\n", p, strerror(errno)); return -1;
  }
  close(fd);
  blen = 0; buf[0] = 0;
  return 0;
}

// ------------------------------------------------------------------------------------ sample
static int nfans = -1;
static int sample(char *line, size_t cap, int *busy) {
  fand_t f; fand_status(&f);
  static fand_t last;                                   // keep the last known sensor list
  if (f.ok) last = f; else { int ns = last.nsens; memcpy(f.sens, last.sens, sizeof f.sens); f.nsens = ns; }
  if (nfans < 0) { int v = smc_int("FNum"); if (v >= 0) nfans = v > MAX_FANS ? MAX_FANS : v; }   // retried until readable
  int nf = nfans < 0 ? 0 : nfans;
  static const char *pk[] = { "PDTR", "PCPT", "PCTR", "PG0R", "PZ2G" };
  // header (changes only with the sensor list; then a new header line is written)
  size_t h = 0;
  #define HDR(...) do { int _n = snprintf(header + h, h < sizeof header ? sizeof header - h : 0, __VA_ARGS__); if (_n > 0) h += (size_t)_n; } while (0)
  HDR("#epoch,mode,profile,shift,cpu,gpu,fs");
  for (int n = 0; n < nf; n++) HDR(",F%dAc,F%dTg", n, n);
  for (int i = 0; i < 5; i++) HDR(",%s", pk[i]);
  for (int i = 0; i < f.nsens; i++) HDR(",%s", f.sens[i]);
  HDR(",HDD\n");
  #undef HDR
  if (h >= sizeof header) return -1;

  size_t o = 0; int anyfan = 0;
  #define OUT(...) do { int _n = snprintf(line + o, o < cap ? cap - o : 0, __VA_ARGS__); if (_n > 0) o += (size_t)_n; } while (0)
  #define NUM(fmt, v) do { if (isnan(v)) OUT(","); else OUT("," fmt, v); } while (0)
  OUT("%ld,%s,%s", (long)time(NULL), f.mode, f.profile);
  NUM("%.1f", f.shift); NUM("%.2f", f.cpu); NUM("%.2f", f.gpu);
  int fs = smc_int("FS! "); OUT(",%d", fs);
  for (int n = 0; n < nf; n++) {
    char k[8]; snprintf(k, sizeof k, "F%dAc", n); double ac = smc_fpe2(k);
    snprintf(k, sizeof k, "F%dTg", n); double tg = smc_fpe2(k);
    NUM("%.0f", ac); NUM("%.0f", tg); if (ac > 100) anyfan = 1;
  }
  for (int i = 0; i < 5; i++) NUM("%.2f", smc_watts(pk[i]));
  for (int i = 0; i < f.nsens; i++) NUM("%.2f", smc_temp(f.sens[i]));
  NUM("%.0f", f.hdd);
  OUT("\n");
  #undef NUM
  #undef OUT
  *busy = anyfan || (!isnan(f.cpu) && f.cpu > 0.10) || (!isnan(f.gpu) && f.gpu > 0.10);
  return o < cap ? 0 : -1;
}

static void day_of(time_t t, char *d, size_t cap) { struct tm tm; localtime_r(&t, &tm); strftime(d, cap, "%Y-%m-%d", &tm); }

int main(int argc, char **argv) {
  if (argc < 2 || (strcmp(argv[1], "log") && strcmp(argv[1], "once"))) {
    fprintf(stderr, "usage: sofa-fanlearn log [-o dir] [-f flush_s] | once\n"); return 2;
  }
  if (smc_open()) { fprintf(stderr, "sofa-fanlearn: AppleSMC not available\n"); return 1; }
  char line[4096]; int busy = 0;
  if (!strcmp(argv[1], "once")) {
    if (sample(line, sizeof line, &busy)) return 1;
    fputs(header, stdout); fputs(line, stdout); return 0;
  }
  int flush_s = 4 * 3600;
  const char *home = getenv("HOME");
  snprintf(outdir, sizeof outdir, "%s/Library/Logs/sofa-fanlearn", home ? home : "/tmp");
  for (int i = 2; i < argc; i++) {
    if (!strcmp(argv[i], "-o") && i + 1 < argc) snprintf(outdir, sizeof outdir, "%s", argv[++i]);
    else if (!strcmp(argv[i], "-f") && i + 1 < argc) { flush_s = atoi(argv[++i]); if (flush_s < 10) flush_s = 10; }
    else { fprintf(stderr, "sofa-fanlearn: unknown argument %s\n", argv[i]); return 2; }
  }
  if (mkdir(outdir, 0755) && errno != EEXIST) { fprintf(stderr, "sofa-fanlearn: mkdir %s: %s\n", outdir, strerror(errno)); return 1; }
  buf = malloc(BUF_MAX); if (!buf) return 1; buf[0] = 0;
  struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = on_sig;   // no SA_RESTART: sleep returns
  sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL); sigaction(SIGHUP, &sa, NULL);
  sigset_t blk, orig; sigemptyset(&blk); sigaddset(&blk, SIGTERM); sigaddset(&blk, SIGINT); sigaddset(&blk, SIGHUP);
  sigprocmask(SIG_BLOCK, &blk, &orig);
  prune();
  time_t last_flush = time(NULL);
  day_of(last_flush, cur_day, sizeof cur_day);
  fprintf(stderr, "sofa-fanlearn: logging to %s, flush every %d s\n", outdir, flush_s);
  while (!stop) {
    time_t now = time(NULL); char d[16]; day_of(now, d, sizeof d);
    if (strcmp(d, cur_day) && flush_buf() == 0) { snprintf(cur_day, sizeof cur_day, "%s", d); last_header[0] = 0; prune(); }
    if (sample(line, sizeof line, &busy) == 0) {
      if (blen + strlen(header) + strlen(line) + 1 > BUF_MAX) flush_buf();
      if (strcmp(header, last_header)) { bappend(header); snprintf(last_header, sizeof last_header, "%s", header); }
      bappend(line);
    }
    if (flush_now || now - last_flush >= flush_s) { flush_now = 0; flush_buf(); last_flush = now; }
    // signals are blocked except inside pselect: a SIGTERM can never slip in before the wait
    struct timespec ts = { busy ? DT_BUSY : DT_CALM, 0 };
    if (!stop && !flush_now) pselect(0, NULL, NULL, NULL, &ts, &orig);
  }
  flush_buf();
  return 0;
}
