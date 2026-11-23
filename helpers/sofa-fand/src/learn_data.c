// The recorder's rows -> one-minute bins, and measured metrics per mode.
//
// Files: DATA_DIR/YYYY-MM-DD.csv, '#' header lines name the columns (read by name; unknown columns
// are ignored, so recorder versions and migrated collector files mix). tests.csv lists the
// identification intervals of migrated data; the recorder itself tags its rows (column "test").
// A Mac without power keys gets load proxies (cpu, gpu share x 20 W): the model's coefficients
// absorb the scale.
#include "learn.h"
#include <dirent.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

const char *mode_label[MODE_N] = { "ruhe", "idle", "playback", "test" };

enum { C_NONE, C_EPOCH, C_MODE, C_PROF, C_VOL, C_CPU, C_GPU, C_TEST, C_PT, C_PC, C_PG, C_FAN0, C_TEMP0 = C_FAN0 + MAX_FANS };
#define MAX_COLS 256

typedef struct {
  double t; int prof, curve, test, rows;
  double sum[C_TEMP0 + MAX_SENS], cnt[C_TEMP0 + MAX_SENS], amb_s, amb_n;
} acc_t;

typedef struct { double a, b; } span_t;
static span_t *tests; static int ntests;

static void load_tests(const char *dir) {
  char p[300]; snprintf(p, sizeof p, "%s/tests.csv", dir);
  FILE *f = fopen(p, "r"); if (!f) return;
  char line[256]; int cap = 0;
  while (fgets(line, sizeof line, f)) {
    double a, b; if (sscanf(line, "%lf,%lf", &a, &b) != 2 || b <= a) continue;
    if (ntests == cap) { cap = cap ? cap * 2 : 64; span_t *n = realloc(tests, (size_t)cap * sizeof *n); if (!n) break; tests = n; }
    tests[ntests].a = a; tests[ntests].b = b; ntests++;
  }
  fclose(f);
}
static int in_test(double t) { for (int i = 0; i < ntests; i++) if (t >= tests[i].a && t < tests[i].b) return 1; return 0; }

static int cmpstr(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

static int prof_of(const char *s) { for (int p = 0; p < P_COUNT; p++) if (!strcmp(s, prof_name[p])) return p; return -1; }

static void finish_bin(bin_t *b, const acc_t *a, const cfg_t *c, int have_power) {
  #define MEAN(k) (a->cnt[k] > 0 ? a->sum[k] / a->cnt[k] : NAN)
  memset(b, 0, sizeof *b);
  b->t = a->t; b->prof = a->prof; b->curve = a->curve; b->test = a->test;
  b->vol = MEAN(C_VOL); b->cpu = MEAN(C_CPU); b->gpu = MEAN(C_GPU);
  for (int n = 0; n < MAX_FANS; n++) b->fan[n] = MEAN(C_FAN0 + n);
  double pt = MEAN(C_PT), pc = MEAN(C_PC), pg = MEAN(C_PG);
  if (have_power) {
    b->pc = pc; b->pg = pg;
    b->pr = isnan(pt) || isnan(pc) || isnan(pg) ? NAN : fmax(0, pt - pc - pg);
  } else { b->pc = isnan(b->cpu) ? NAN : 20 * b->cpu; b->pg = isnan(b->gpu) ? NAN : 20 * b->gpu; b->pr = 0; }
  b->amb = a->amb_n > 0 ? a->amb_s / a->amb_n : NAN;
  for (int i = 0; i < c->nsens; i++) b->temp[i] = MEAN(C_TEMP0 + i);
  #undef MEAN
}

int data_load(series_t *s, const cfg_t *c, const machine_t *m, const char *dir, double since) {
  memset(s, 0, sizeof *s);
  ntests = 0; load_tests(dir);
  DIR *dp = opendir(dir); if (!dp) return -1;
  char *names[512]; int nn = 0; struct dirent *e;
  while ((e = readdir(dp)) && nn < 512) {
    int y, mo, da; char tail[8];
    if (sscanf(e->d_name, "%4d-%2d-%2d.%7s", &y, &mo, &da, tail) != 4 || strcmp(tail, "csv")) continue;
    struct tm tm = { 0 }; tm.tm_year = y - 1900; tm.tm_mon = mo - 1; tm.tm_mday = da + 1; tm.tm_isdst = -1;
    if ((double)mktime(&tm) < since) continue;               // the whole day lies before `since`
    names[nn++] = strdup(e->d_name);
  }
  closedir(dp);
  qsort(names, (size_t)nn, sizeof *names, cmpstr);
  int have_power = m && m->ok && m->pw_cpu[0] && m->pw_gpu[0];
  int cap = 0; acc_t acc; int open = 0;
  static int col[MAX_COLS]; int ncol = 0, amb_col = -1;
  static char line[16384];
  for (int f = 0; f < nn; f++) {
    char p[300]; snprintf(p, sizeof p, "%s/%s", dir, names[f]); free(names[f]);
    FILE *fp = fopen(p, "r"); if (!fp) continue;
    ncol = 0;
    while (fgets(line, sizeof line, fp)) {
      char *tok; int k = 0;
      if (line[0] == '#') {                                  // column names
        ncol = 0; amb_col = -1;
        for (char *q = line + 1; (tok = strsep(&q, ",\n")) && ncol < MAX_COLS; ) {
          if (!*tok && !q) break;
          int id = C_NONE;
          if (!strcmp(tok, "epoch")) id = C_EPOCH; else if (!strcmp(tok, "mode")) id = C_MODE; else if (!strcmp(tok, "profile")) id = C_PROF;
          else if (!strcmp(tok, "vol")) id = C_VOL; else if (!strcmp(tok, "cpu")) id = C_CPU; else if (!strcmp(tok, "gpu")) id = C_GPU;
          else if (!strcmp(tok, "test")) id = C_TEST;
          else if (m && m->pw_total[0] && !strcmp(tok, m->pw_total)) id = C_PT;
          else if (m && m->pw_cpu[0] && !strcmp(tok, m->pw_cpu)) id = C_PC;
          else if (m && m->pw_gpu[0] && !strcmp(tok, m->pw_gpu)) id = C_PG;
          else if (tok[0] == 'F' && tok[1] >= '0' && tok[1] < '0' + MAX_FANS && !strcmp(tok + 2, "Ac")) id = C_FAN0 + (tok[1] - '0');
          else { int si = sens_index(c, tok); if (si >= 0) id = C_TEMP0 + si; }
          if (m && m->ambient[0] && !strcmp(tok, m->ambient)) amb_col = ncol;
          col[ncol++] = id;
        }
        continue;
      }
      if (!ncol) continue;
      double t = NAN; int prof = -1, curve = 0, test = 0;
      double val[MAX_COLS]; char *q = line;
      for (k = 0; k < ncol && (tok = strsep(&q, ",\n")); k++) {
        val[k] = NAN;
        if (!*tok) continue;
        switch (col[k]) {
          case C_EPOCH: t = atof(tok); break;
          case C_MODE: curve = !strcmp(tok, "curve"); break;
          case C_PROF: prof = prof_of(tok); break;
          case C_TEST: test = 1; break;
          default: { char *end; double v = strtod(tok, &end); if (end != tok) val[k] = v; }
        }
      }
      if (isnan(t) || t < since || k < ncol) continue;       // short row: cut off by a crash
      if (in_test(t)) test = 1;
      double minute = floor(t / 60) * 60;
      if (open && minute < acc.t) continue;                  // out of order: dropped
      if (!open || minute > acc.t) {
        if (open && acc.rows) {
          if (s->n == cap) { cap = cap ? cap * 2 : 4096; bin_t *nb = realloc(s->b, (size_t)cap * sizeof *nb); if (!nb) { fclose(fp); return -1; } s->b = nb; }
          finish_bin(&s->b[s->n++], &acc, c, have_power);
        }
        memset(&acc, 0, sizeof acc); acc.t = minute; acc.curve = 1; open = 1;
      }
      acc.rows++;
      acc.prof = prof; acc.curve &= curve; acc.test |= test;
      for (k = 0; k < ncol; k++) {
        if (isnan(val[k])) continue;
        if (k == amb_col) { acc.amb_s += val[k]; acc.amb_n++; }
        int id = col[k];
        if (id == C_NONE || id == C_EPOCH || id == C_MODE || id == C_PROF || id == C_TEST) continue;
        if (id >= C_FAN0 && id < C_TEMP0 && val[k] < 0) continue;
        if (id >= C_TEMP0 && (val[k] < 5 || val[k] > 125)) continue;
        acc.sum[id] += val[k]; acc.cnt[id]++;
      }
    }
    fclose(fp);
  }
  if (open && acc.rows) {
    if (s->n == cap) { bin_t *nb = realloc(s->b, (size_t)(cap + 1) * sizeof *nb); if (!nb) return -1; s->b = nb; }
    finish_bin(&s->b[s->n++], &acc, c, have_power);
  }
  if (!m || !m->ambient[0]) for (int i = 0; i < s->n; i++) s->b[i].amb = 22;   // no ambient key: a constant (a0 absorbs it)
  return 0;
}

void data_free(series_t *s) { free(s->b); s->b = NULL; s->n = 0; }

int bin_mode(const bin_t *b) {
  if (b->test) return MD_TEST;
  if (!b->curve) return -1;
  if (b->prof == P_RUHE) return MD_RUHE;
  if (b->prof == P_PLAYBACK) return MD_PLAY;
  if (b->prof == P_IDLE || b->prof == P_DEFAULT) return MD_IDLE;
  return -1;
}

int bin_inputs(const bin_t *b, const cfg_t *c) {
  if (isnan(b->pc) || isnan(b->pg) || isnan(b->pr) || isnan(b->amb)) return 0;
  for (int n = 0; n < MAX_FANS; n++) if (c->fan[n].used && isnan(b->fan[n])) return 0;
  return 1;
}

int bin_next(const series_t *s, int i) { return i + 1 < s->n && s->b[i + 1].t - s->b[i].t < 61; }

double fan_noise(const cfg_t *c, const double *rpm) {
  double z = 0;
  for (int n = 0; n < MAX_FANS; n++) if (c->fan[n].used) { double r = rpm[n] / 1000; z += c->fan[n].loud * r * r; }
  return z;
}

// 0.1 C histogram of T - ambient, -20..100
#define HB 1200
void measure(metric_t out[MODE_N], const series_t *d, const cfg_t *c, double from, double to) {
  static unsigned short hist[MODE_N][MAX_SENS][HB];
  static unsigned hn[MODE_N][MAX_SENS];
  memset(hist, 0, sizeof hist); memset(hn, 0, sizeof hn);
  for (int md = 0; md < MODE_N; md++) memset(&out[md], 0, sizeof out[md]);
  for (int i = 0; i < d->n; i++) {
    const bin_t *b = &d->b[i];
    if (b->t < from || b->t >= to || !bin_inputs(b, c)) continue;
    int md = bin_mode(b); if (md < 0) continue;
    metric_t *o = &out[md];
    o->minutes++; o->noise += fan_noise(c, b->fan); o->amb += b->amb;
    int warn = 0;
    for (int s = 0; s < c->nsens; s++) {
      if (isnan(b->temp[s])) continue;
      if (b->temp[s] >= c->sens[s].warn) warn = 1;
      int h = (int)lround((b->temp[s] - b->amb + 20) * 10);
      if (h < 0) h = 0;
      if (h >= HB) h = HB - 1;
      if (hist[md][s][h] < 65535) hist[md][s][h]++;
      hn[md][s]++;
    }
    o->warn_min += warn;
  }
  for (int md = 0; md < MODE_N; md++) {
    metric_t *o = &out[md];
    if (o->minutes > 0) { o->noise /= o->minutes; o->amb /= o->minutes; }
    for (int s = 0; s < c->nsens; s++) {
      o->p95[s] = NAN;
      if (hn[md][s] < 30) continue;
      unsigned want = (unsigned)ceil(hn[md][s] * 0.95), cum = 0;
      for (int h = 0; h < HB; h++) { cum += hist[md][s][h]; if (cum >= want) { o->p95[s] = h / 10.0 - 20; break; } }
    }
  }
}
