// Trial: an applied step is judged on measured data, never on the model alone.
//
// Judged after >= 2 days and >= 10 h of regulated use minutes since it was applied (at the latest
// after 10 days, with what there is), against the 7 days before it - per mode, so a week of films
// is not compared with a week of rest:
//   - roll back on more warn minutes per hour than before,
//   - roll back when a sensor's 95 % temperature over ambient rose by more than 1 C in a mode and
//     now lies above its target,
//   - a quieter (or mixed) step must also have made the measured fan noise lower (by 2 %, weighted
//     like the cost: time share x profile noise); otherwise it is rolled back as "no gain".
// A rolled-back step's directions are not tried again for 14 days (rejected list).
#include "learn.h"
#include <errno.h>
#include <math.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define DAY 86400.0

int trial_load(trial_t *t) {
  memset(t, 0, sizeof *t);
  FILE *f = fopen(TRIAL_PATH, "r"); if (!f) return 0;
  char line[1200];
  while (fgets(line, sizeof line, f)) {
    char *nl = strchr(line, '\n'); if (nl) *nl = 0;
    if (!strncmp(line, "applied ", 8)) t->applied = atof(line + 8);
    else if (!strncmp(line, "kind ", 5)) snprintf(t->kind, sizeof t->kind, "%s", line + 5);
    else if (!strncmp(line, "keys ", 5)) snprintf(t->keys, sizeof t->keys, "%s", line + 5);
    else if (!strncmp(line, "what ", 5)) snprintf(t->what, sizeof t->what, "%s", line + 5);
  }
  fclose(f);
  t->active = t->applied > 0;
  return 0;
}

int trial_save(const trial_t *t) {
  if (!t->active) return unlink(TRIAL_PATH) && errno != ENOENT ? -1 : 0;
  char tmp[] = TRIAL_PATH ".tmp";
  FILE *f = fopen(tmp, "w"); if (!f) return -1;
  fprintf(f, "applied %.0f\nkind %s\nkeys %s\nwhat %s\n", t->applied, t->kind, t->keys, t->what);
  if (fclose(f)) return -1;
  return rename(tmp, TRIAL_PATH);
}

void history(const char *fmt, ...) {
  FILE *f = fopen(HISTORY_PATH, "a"); if (!f) return;
  time_t now = time(NULL); struct tm tm; localtime_r(&now, &tm);
  char ts[32]; strftime(ts, sizeof ts, "%Y-%m-%d %H:%M", &tm);
  fprintf(f, "%s ", ts);
  va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
  fprintf(f, "\n"); fclose(f);
}

int rejected_recently(const char *key) {
  FILE *f = fopen(REJECTED_PATH, "r"); if (!f) return 0;
  char line[128]; double cut = (double)time(NULL) - 14 * DAY; int hit = 0;
  while (fgets(line, sizeof line, f)) {
    double t; char k[64];
    if (sscanf(line, "%lf %63s", &t, k) == 2 && t >= cut && !strcmp(k, key)) { hit = 1; break; }
  }
  fclose(f);
  return hit;
}

void rejected_add(const char *keys) {
  FILE *f = fopen(REJECTED_PATH, "a"); if (!f) return;
  char buf[256]; snprintf(buf, sizeof buf, "%s", keys);
  for (char *q = buf, *k; (k = strsep(&q, " ")); ) if (*k) fprintf(f, "%ld %s\n", (long)time(NULL), k);
  fclose(f);
}

// noise weighted like the cost: time share of the mode x profile noise
static double weighted_noise(const metric_t *mt, const cfg_t *c, const double *share) {
  static const int prof[MODE_N] = { P_RUHE, P_IDLE, P_PLAYBACK, -1 };
  double z = 0;
  for (int md = 0; md < MD_TEST; md++) if (share[md] > 0 && mt[md].minutes > 0) z += share[md] * c->prof[prof[md]].noise * mt[md].noise;
  return z;
}

int trial_judge(const trial_t *t, const series_t *d, const cfg_t *c, char *why, size_t cap, FILE *rep) {
  double now = (double)time(NULL);
  metric_t before[MODE_N], after[MODE_N];
  measure(before, d, c, t->applied - 7 * DAY, t->applied);
  measure(after, d, c, t->applied, now);
  double use_after = after[MD_RUHE].minutes + after[MD_IDLE].minutes + after[MD_PLAY].minutes;
  double use_before = before[MD_RUHE].minutes + before[MD_IDLE].minutes + before[MD_PLAY].minutes;
  double days = (now - t->applied) / DAY;
  if (rep) {
    fprintf(rep, "\n## Trial\n\nApplied %.1f days ago (%s): %s\n\n| mode | minutes before / after | noise before / after | warn min before / after |\n|---|---|---|---|\n", days, t->kind, t->what);
    for (int md = 0; md < MD_TEST; md++)
      fprintf(rep, "| %s | %.0f / %.0f | %.2f / %.2f | %.0f / %.0f |\n", mode_label[md], before[md].minutes, after[md].minutes, before[md].noise, after[md].noise, before[md].warn_min, after[md].warn_min);
  }
  if (days < 2 || (use_after < 600 && days < 10)) { snprintf(why, cap, "on trial (%.1f days, %.0f use minutes; judged after 2 days and 600 minutes)", days, use_after); return 0; }
  if (use_before < 600) { snprintf(why, cap, "kept: too little data before the step to compare (%.0f minutes)", use_before); return 1; }
  double wb = 0, wa = 0;
  for (int md = 0; md < MD_TEST; md++) { wb += before[md].warn_min; wa += after[md].warn_min; }
  if (wa > 0 && wa / use_after > wb / use_before + 1e-9) { snprintf(why, cap, "warn reached %.0f minutes (before %.0f in %.0f minutes)", wa, wb, use_before); return -1; }
  for (int md = 0; md < MD_TEST; md++) {
    if (before[md].minutes < 120 || after[md].minutes < 120) continue;
    for (int s = 0; s < c->nsens; s++) {
      double a = after[md].p95[s], b = before[md].p95[s];
      if (isnan(a) || isnan(b)) continue;
      if (a > b + 1.0 && a + after[md].amb > c->sens[s].target) {
        snprintf(why, cap, "%s in %s: 95 %% at %.1f C over ambient (before %.1f), above its target %.0f", c->sens[s].key, mode_label[md], a, b, c->sens[s].target);
        return -1;
      }
    }
  }
  if (strcmp(t->kind, "cooler")) {
    double share[MODE_N] = { 0 };
    for (int md = 0; md < MD_TEST; md++) share[md] = (before[md].minutes + after[md].minutes) / (use_before + use_after);
    double nb = weighted_noise(before, c, share), na = weighted_noise(after, c, share);
    if (na >= nb * 0.98) { snprintf(why, cap, "no measurable gain: noise %.3f after, %.3f before", na, nb); return -1; }
    snprintf(why, cap, "kept: noise %.3f after, %.3f before, no temperature regression", na, nb);
    return 1;
  }
  snprintf(why, cap, "kept: no warn, no temperature regression");
  return 1;
}
