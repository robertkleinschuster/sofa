// Logging without disk or syslog in the control loop: lines go into a RAM ring, a thread hands
// them to syslog. The guard writes into the shared page instead; the controller's log thread
// passes its lines on too.
#include "fand.h"
#include <stdarg.h>
#include <string.h>
#include <sys/time.h>
#include <syslog.h>
#include <time.h>

#define LOG_LINES 64
#define LOG_LEN   176
static char log_ring[LOG_LINES][LOG_LEN];
static unsigned log_head, log_sent;
static pthread_mutex_t log_mx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t log_cv = PTHREAD_COND_INITIALIZER;
static int log_threaded;
static unsigned glog_seen;
shared_t *shm;
shcfg_t *shcfg;

void logf_(const char *fmt, ...) {
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

static void drain_guard_log(void) {
  if (!shm) return;
  unsigned h = shm->glog_head;
  if (h - glog_seen > GLOG_LINES) glog_seen = h - GLOG_LINES;
  for (; glog_seen != h; glog_seen++) { char l[160]; memcpy(l, shm->glog[glog_seen % GLOG_LINES], sizeof l); l[159] = 0; syslog(LOG_ERR, "guard: %s", l); shm->glog_printed = glog_seen + 1; }
}

void log_start_threaded(void) { glog_seen = shm ? shm->glog_printed : 0; log_threaded = 1; }   // only what no controller printed yet

void *log_thread(void *arg) {
  (void)arg;
  for (;;) {
    char line[LOG_LEN];
    pthread_mutex_lock(&log_mx);
    while (log_sent == log_head) {
      // wake every 10 s to pass on the guard's lines
      struct timespec ts; struct timeval tv; gettimeofday(&tv, NULL);
      ts.tv_sec = tv.tv_sec + 10; ts.tv_nsec = tv.tv_usec * 1000;   // guard lines are rare
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

void guard_log(const char *fmt, ...) {
  char line[160]; va_list ap; va_start(ap, fmt); vsnprintf(line, sizeof line, fmt, ap); va_end(ap);
  if (!shm) { syslog(LOG_ERR, "%s", line); return; }
  unsigned h = shm->glog_head;
  memcpy(shm->glog[h % GLOG_LINES], line, sizeof line);
  __sync_synchronize();
  shm->glog_head = h + 1;
}

void log_recent(void (*out)(const char *line, void *ctx), void *ctx, unsigned n) {
  pthread_mutex_lock(&log_mx);
  unsigned from = log_head > n ? log_head - n : 0;
  for (unsigned i = from; i < log_head; i++) out(log_ring[i % LOG_LINES], ctx);
  pthread_mutex_unlock(&log_mx);
}
