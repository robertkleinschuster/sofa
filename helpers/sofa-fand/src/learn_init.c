// A reference for any Mac, from the SMC alone (`sofa-fand init`), and the quiet bootstrap the
// learner proposes once its model is validated.
//
// init: Apple-equivalent - every fan at Apple's minimum, ramping to its maximum between a sensor's
// fan-start (or control target) and warn, on every fan (Apple's sensor-to-fan mapping is not
// readable, so every fan answers every sensor). Sensors: one per family (TC0, TG0, TL0, ...) that
// has an Apple limit or target, the ambient key, the Apple-minimum floors come from the SMC anyway.
// Nothing measured yet, nothing quieter than Apple.
//
// bootstrap: once the model is trusted in every use mode, a reference made by `init` is replaced by
// one with real "minimum 0" curves: each fan answers only the sensors it measurably cools (at full
// speed >= 10 % of the heat flow out), off below target - 4, minrun at target - 2, max at warn.
// Installed like a learned step: on trial, judged on measured data, rolled back if it does worse.
#include "learn.h"
#include <ctype.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int family_seen(char fam[][4], int n, const char *k) { for (int i = 0; i < n; i++) if (!strncmp(fam[i], k, 3)) return 1; return 0; }

static int pick(const machine_t *m, int *idx) {
  char fam[MAX_SENS][4]; int n = 0;
  if (m->ambient[0]) for (int i = 0; i < m->nsens; i++) if (!strcmp(m->sens[i].key, m->ambient)) { idx[n] = i; memcpy(fam[n], m->ambient, 3); fam[n][3] = 0; n++; }
  for (int pass = 0; pass < 2 && n < MAX_SENS - 4; pass++)
    for (int i = 0; i < m->nsens && n < MAX_SENS - 4; i++) {
      const msens_t *s = &m->sens[i];
      int has = s->warn || s->throttle || s->shutdown || s->target;
      if (!has || islower((unsigned char)s->key[3]) != pass || family_seen(fam, n, s->key)) continue;   // uppercase (proximity/die) keys first
      idx[n] = i; memcpy(fam[n], s->key, 3); fam[n][3] = 0; n++;
    }
  return n;
}

static void limits(const msens_t *s, double *trip, double *warn, double *start) {
  if (s->warn || s->throttle || s->shutdown) {
    *trip = s->warn ? s->warn : s->throttle ? s->throttle - 2 : s->shutdown - 5;
    *warn = *trip - 6;
  } else { *warn = s->target + 2; *trip = s->target + 8; }
  *start = s->fan_start ? s->fan_start : s->target ? s->target - 3 : *warn - 8;
  if (*start > *warn - 2) *start = *warn - 2;
}

int init_reference(FILE *o, const machine_t *m) {
  if (!m->ok) return -1;
  int idx[MAX_SENS]; int ns = pick(m, idx);
  fprintf(o, INIT_MARK " for %s: Apple-equivalent reference from the SMC (no measurements yet).\n", m->model);
  fprintf(o, "# Every fan at Apple's minimum, ramping to its maximum between fan start / target and warn.\n");
  fprintf(o, "# The learner replaces it with quiet curves once its model is validated (bootstrap, on trial).\n\n");
  for (int i = 0; i < ns; i++) {
    const msens_t *s = &m->sens[idx[i]];
    if (!strcmp(s->key, m->ambient)) { fprintf(o, "sensor %s trip 45 warn 40     # ambient: monitored, the model's reference\n", s->key); continue; }
    double trip, warn, start; limits(s, &trip, &warn, &start);
    const char *ff = s->key[1] == 'C' ? " ff cpu" : s->key[1] == 'G' ? " ff gpu" : "";
    fprintf(o, "sensor %s trip %.1f warn %.1f%s%s\n", s->key, trip, warn, ff, s->target ? " fast 1" : "");
  }
  for (int n = 0; n < m->nfans; n++) {
    int min = m->fan[n].min > 0 ? m->fan[n].min : m->fan[n].max / 3;
    fprintf(o, "\nfan %d minrun %d hyst 3 up 150 down 15 minon 120 minoff 120\n", n, min);
    int nc = 0;
    for (int i = 0; i < ns && nc < MAX_CURVES; i++) {
      const msens_t *s = &m->sens[idx[i]];
      if (!strcmp(s->key, m->ambient)) continue;
      double trip, warn, start; limits(s, &trip, &warn, &start);
      fprintf(o, "curve %d %s %.1f:%d %.1f:%d\n", n, s->key, start, min, warn, m->fan[n].max);
      nc++;
    }
  }
  fprintf(o, "\nprofile default 0\nprofile ruhe 0\nprofile idle 0 learn cooler\nprofile playback 0 learn cooler\n");
  fprintf(o, "feedforward 0 0 3000\nhdd_interval 30\nhdd_stale 150\ntrip_hold 300\nallow_uid %d\n", getenv("SUDO_UID") ? atoi(getenv("SUDO_UID")) : 501);
  return 0;
}

int bootstrap_reference(FILE *o, const cfg_t *ref, const model_t *m, const machine_t *mc) {
  fprintf(o, INIT_MARK " bootstrap for %s: quiet curves from the learned coupling (model of %s).\n\n", mc->model, "the recorded data");
  for (int s = 0; s < ref->nsens; s++) {
    const sens_cfg_t *sc = &ref->sens[s];
    static const char *ffn[] = { "none", "cpu", "gpu", "both" };
    fprintf(o, "sensor %s trip %.1f warn %.1f target %.1f ff %s%s\n", sc->key, sc->trip, sc->warn, sc->target, ffn[sc->ff], sc->fast ? " fast 1" : "");
  }
  for (int n = 0; n < MAX_FANS; n++) {
    const fan_cfg_t *f = &ref->fan[n];
    if (!f->used) continue;
    fprintf(o, "\nfan %d minrun %d hyst %.1f up %.0f down %.0f minon %d minoff %d loud %.1f\n", n, f->minrun, f->hyst, f->up, f->down, f->minon, f->minoff, f->loud);
    int nc = 0;
    for (int s = 0; s < ref->nsens && nc < MAX_CURVES; s++) {
      const smodel_t *sm = &m->s[s];
      if (!sm->ok || sm->fixed || !sensor_steers(ref, s)) continue;
      double kf = sm->th[5 + n] * f->max / 1000, k0 = sm->th[4];
      if (kf + k0 <= 0 || kf / (kf + k0) < 0.10) continue;    // this fan barely moves this sensor
      const sens_cfg_t *sc = &ref->sens[s];
      double t0 = sc->target - 4, t1 = sc->target - 2, t2 = sc->target + 1, w = sc->warn;
      if (t2 >= w) t2 = w - 0.5;
      if (t1 >= t2) t1 = t2 - 0.5;
      if (t0 >= t1) t0 = t1 - 0.5;
      fprintf(o, "curve %d %s %.1f:0 %.1f:%d %.1f:%d %.1f:%d\n", n, sc->key, t0, t1, f->minrun, t2, (f->minrun + f->max) / 2, w, f->max);
      nc++;
    }
    for (int k = 0; k < f->nfloors; k++) if (!f->floors[k].machine) fprintf(o, "floor %d %s %g %d\n", n, ref->sens[f->floors[k].sensor].key, f->floors[k].temp, f->floors[k].rpm);
    if (!nc)                                                   // cools nothing measurably: keep its reference curves
      for (int k = 0; k < f->ncurves; k++) {
        const curve_t *cv = &f->curves[k];
        if (cv->learned) continue;
        fprintf(o, "curve %d %s", n, ref->sens[cv->sensor].key);
        for (int i = 0; i < cv->npts; i++) fprintf(o, " %g:%g", cv->pts[i].t, cv->pts[i].rpm);
        fprintf(o, "\n");
      }
  }
  fprintf(o, "\n");
  for (int p = 0; p < P_COUNT; p++) fprintf(o, "profile %s %g %g%s noise %g\n", prof_name[p], ref->prof[p].base, ref->prof[p].vol, ref->prof[p].learn == LEARN_COOLER ? " learn cooler" : "", ref->prof[p].noise);
  fprintf(o, "feedforward %g %g %g\nhdd_interval %d\nhdd_stale %d\ntrip_hold %d\nallow_uid %d\n", ref->ff_cpu, ref->ff_gpu, ref->gpu_full, ref->hdd_interval, ref->hdd_stale, ref->trip_hold, ref->allow_uid);
  return 0;
}
