// The recorder: what the learner learns from, written by the daemon itself (no separate collector).
//
// Every 20 s (10 s while a fan runs, under load or during an identification step) one row: wall-clock
// time, mode, profile, volume, smoothed load, identification tag, per fan actual and commanded speed,
// the machine's power keys (W) and every configured sensor. Rows wait in RAM and go to
// /var/db/sofa-fand/data/YYYY-MM-DD.csv every hour, on request (reload, ctl FLUSH: within ~20 s) and on
// exit - while the controller runs, the disk is touched by this thread only, never by the control loop. A '#' line names the columns before every flush; the
// learner reads columns by name, so the set may change at any time. Files older than 180 days go.
#include "fand.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define REC_BUF   (384 * 1024)
#define REC_FLUSH 3600.0
#define KEEP_DAYS 180

static char buf[REC_BUF]; static size_t used;
static char header[2048];
static char day_of_buf[16];          // the day the buffered rows belong to
static pthread_mutex_t rec_mx = PTHREAD_MUTEX_INITIALIZER;
static double last_flush;

static int ensure_dir(void) {
  struct stat sd;
  if (lstat(DATA_DIR, &sd) && errno == ENOENT) { mkdir(LEARNED_DIR, 0755); mkdir(DATA_DIR, 0755); }
  return lstat(DATA_DIR, &sd) == 0 && S_ISDIR(sd.st_mode) && sd.st_uid == 0 ? 0 : -1;
}

static void prune(void) {
  DIR *d = opendir(DATA_DIR); if (!d) return;
  time_t cut = time(NULL) - KEEP_DAYS * 86400; struct dirent *e;
  while ((e = readdir(d))) {
    int y, mo, da; char tail[8];
    if (sscanf(e->d_name, "%4d-%2d-%2d.%7s", &y, &mo, &da, tail) != 4 || strcmp(tail, "csv")) continue;
    struct tm tm = { 0 }; tm.tm_year = y - 1900; tm.tm_mon = mo - 1; tm.tm_mday = da; tm.tm_isdst = -1;
    if (mktime(&tm) < cut) { char p[256]; snprintf(p, sizeof p, "%s/%s", DATA_DIR, e->d_name); unlink(p); }
  }
  closedir(d);
}

// caller holds rec_mx
static void flush_locked(void) {
  last_flush = now_s();
  if (!used) return;
  if (ensure_dir() == 0) {
    char p[256]; snprintf(p, sizeof p, "%s/%s.csv", DATA_DIR, day_of_buf);
    int fd = open(p, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0644);
    if (fd >= 0) {
      ssize_t w = write(fd, header, strlen(header)); (void)w;
      w = write(fd, buf, used); (void)w;
      close(fd);
    }
  }
  used = 0;
}
void record_flush(void) { pthread_mutex_lock(&rec_mx); flush_locked(); pthread_mutex_unlock(&rec_mx); }
static volatile int flush_req;
void record_request_flush(void) { flush_req = 1; }

#define ADD(...) do { int _k = snprintf(row + o, sizeof row - o, __VA_ARGS__); if (_k > 0) o += (size_t)_k; if (o >= sizeof row) o = sizeof row - 1; } while (0)
#define HDR(...) do { int _k = snprintf(hdr + h, sizeof hdr - h, __VA_ARGS__); if (_k > 0) h += (size_t)_k; if (h >= sizeof hdr) h = sizeof hdr - 1; } while (0)

static void sample(double *next_in) {
  pub_t p; pthread_mutex_lock(&pub_mx); p = pub; pthread_mutex_unlock(&pub_mx);
  if (!p.nsens) { *next_in = 5; return; }                  // nothing published yet
  hint_t hi; pthread_mutex_lock(&hint_mx); hi = hint; pthread_mutex_unlock(&hint_mx);
  double now = now_s();
  char row[2048], hdr[2048]; size_t o = 0, h = 0;
  time_t wall = time(NULL); struct tm tm; localtime_r(&wall, &tm);
  char day[16]; strftime(day, sizeof day, "%Y-%m-%d", &tm);
  HDR("#epoch,mode,profile,vol,cpu,gpu,test");
  ADD("%ld,%s,%s,", (long)wall, mode_name[p.mode], prof_name[p.profile]);
  if (hi.ctx >= 0 && now < hi.until && hi.vol >= 0) ADD("%.2f", hi.vol);
  ADD(",%.3f,%.3f,%s", p.cpu, p.gpu, p.ident);
  int running = 0;
  for (int n = 0; n < MAX_FANS; n++) {
    if (n >= machine.nfans) break;
    char k[5]; double ac = NAN; snprintf(k, sizeof k, "F%dAc", n); smc_fpe2(k, &ac);
    HDR(",F%dAc,F%dTg", n, n);
    if (isnan(ac)) ADD(","); else ADD(",%.0f", ac);
    ADD(",%.0f", p.fan_used[n] ? p.target[n] : -1.0);
    if (ac > 100) running = 1;
  }
  const char *pk[3] = { machine.pw_total, machine.pw_cpu, machine.pw_gpu };
  for (int i = 0; i < 3; i++) {
    if (!pk[i][0]) continue;
    double w; HDR(",%s", pk[i]);
    if (smc_num(pk[i], &w) == 0) ADD(",%.2f", w); else ADD(",");
  }
  for (int i = 0; i < p.nsens; i++) {
    double t; int ok;
    HDR(",%s", p.key[i]);
    if (!strcmp(p.key[i], HDD_KEY)) ok = hdd_reading(now, 150, &t);
    else ok = smc_temp(p.key[i], &t) == 0;       // every sensor fresh, also the controller's slow ones
    if (ok) ADD(",%.2f", t); else ADD(",");
  }
  ADD("\n"); HDR("\n");
  pthread_mutex_lock(&rec_mx);
  if (strcmp(day, day_of_buf) || strcmp(hdr, header) || used + o >= sizeof buf) flush_locked();   // new day, new columns, full
  snprintf(day_of_buf, sizeof day_of_buf, "%s", day);
  snprintf(header, sizeof header, "%s", hdr);
  memcpy(buf + used, row, o); used += o;
  if (now - last_flush >= REC_FLUSH) { flush_locked(); prune(); }
  pthread_mutex_unlock(&rec_mx);
  *next_in = running || p.cpu > 0.1 || p.ident[0] ? 10 : 20;
}

void *record_thread(void *arg) {
  (void)arg;
  if (dry) return NULL;             // a dry run never writes the installed daemon's data
  last_flush = now_s();
  for (;;) {
    double next = 20;
    if (!sleeping) sample(&next);
    if (flush_req) { flush_req = 0; record_flush(); }
    sleep((unsigned)next);
  }
  return NULL;
}
