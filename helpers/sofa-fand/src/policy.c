// The fan decision as a pure function: the controller drives the real fans with it, the learner's
// simulator drives the model with it - what is simulated is exactly what runs.
//
// Per fan and step: curves (temperature + feed-forward - profile shift - learned shift -> rpm, the
// highest wins; falling demand read hyst C hotter), floors, on/off discipline (minon/minoff unless a
// floor or a sensor at warn), dead band 0 < x < minrun, ramps. A forced speed (identification step)
// replaces the curves; floors, limits and ramps still apply.
#include "fand.h"
#include <math.h>

void policy_fan(const cfg_t *c, int n, const double *temp, double cpu, double gpu, double shift,
                double now, double dt, double force, fanstate_t *fs, fanstep_t *r) {
  const fan_cfg_t *fc = &c->fan[n];
  r->near_start = 0; r->hot = 0;
  double up = 0, dn = 0;            // demand for rising / falling (falling read hyst C hotter)
  for (int k = 0; k < fc->ncurves; k++) {
    const curve_t *cv = &fc->curves[k];
    const sens_cfg_t *sc = &c->sens[cv->sensor];
    double ff = 0;
    if (sc->ff == FF_CPU || sc->ff == FF_BOTH) ff += c->ff_cpu * cpu;
    if (sc->ff == FF_GPU || sc->ff == FF_BOTH) ff += c->ff_gpu * gpu;
    double te = temp[cv->sensor] + fc->fw * ff - fc->pw * shift - cv->shift;   // learned shift: + = later/quieter
    double u = interp(cv, te), d = interp(cv, te + fc->hyst);
    if (u > up) up = u;
    if (d > dn) dn = d;
    double start = -1e9; for (int q = 0; q < cv->npts && cv->pts[q].rpm <= 0; q++) start = cv->pts[q].t;   // last 0-rpm point
    if (fs->out <= 0 && te >= start - 2) r->near_start = 1;   // a stopped fan within 2 C of a curve start
    if (te >= start - 8) r->hot = 1;                          // within 8 C of a curve start: no deep calm
  }
  // floors: Apple-minimum guarantee etc. (independent of profile, feed-forward, learning, forcing)
  double fl = 0;
  for (int k = 0; k < fc->nfloors; k++) if (temp[fc->floors[k].sensor] >= fc->floors[k].temp && fc->floors[k].rpm > fl) fl = fc->floors[k].rpm;
  int urgent = fl > 0;              // an active floor or a sensor at warn overrides minoff
  for (int k = 0; k < fc->ncurves; k++) { int s = fc->curves[k].sensor; if (temp[s] >= c->sens[s].warn) urgent = 1; }

  double cur = fs->out, want;
  if (force >= 0) want = force;     // identification: a fixed speed, no on/off discipline
  else {
    if (up < fl) up = fl;
    if (dn < fl) dn = fl;
    if (up > cur) want = up;                         // warmer: follow at once (ramp-limited)
    else if (dn < cur) want = dn;                    // cooler past the hysteresis: go down
    else want = cur;                                 // inside the hysteresis band: hold
    if (want > 0 && want < fc->minrun) want = fc->minrun;
    // on/off discipline (mainly a loud fan: its start is the audible part)
    if (cur <= 0 && want > 0 && !urgent && fs->off_since > 0 && now - fs->off_since < fc->minoff) want = 0;
  }
  if (want > 0 && want < fc->minrun) want = fc->minrun;
  if (want < fl) want = fl;         // floors hold in every case
  if (force < 0 && cur > 0 && want <= 0 && now - fs->on_since < fc->minon) want = fc->minrun > 0 ? fc->minrun : cur;
  if (want > fc->max) want = fc->max;
  // ramps
  double next;
  double rdt = dt < DT_FAST ? dt : DT_FAST;   // ramp per step; a moving fan samples every DT_FAST
  if (want > cur) next = cur <= 0 ? (want > fc->minrun ? want : fc->minrun) : (want - cur > fc->up * rdt ? cur + fc->up * rdt : want);
  else if (want < cur) next = (want <= 0 && cur <= (fc->minrun > 0 ? fc->minrun : 0) + 1) ? 0 : (cur - want > fc->down * rdt ? cur - fc->down * rdt : want);
  else next = cur;
  if (next > 0 && next < fc->minrun) next = fc->minrun;   // never inside the dead band 0 < x < minrun
  if (next > fc->max) next = fc->max;
  if (next < 0) next = 0;
  r->started = cur <= 0 && next > 0;
  if (r->started) fs->on_since = now;
  if (cur > 0 && next <= 0) fs->off_since = now;
  r->moving = fabs(next - want) > 1 || fabs(next - cur) > 1 || (next > 0 && now - fs->on_since < 40);
  r->urgent = urgent;
  fs->out = next;
  r->next = next;
}
