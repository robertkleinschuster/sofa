// Scenarios from the data, the closed loop simulated through policy_fan (the controller's own
// decision), and the cost the search minimises.
//
// Scenarios per use mode (rest, in use, playback) with at least 2 h of data: its mean inputs, its
// high-load case (mean of the top 10 % load minutes) and a warm room (mean inputs, ambient + 5 C).
// Each runs 6 h from a cold start (10 % temperatures) and from a hot one (95 % + 2 C), fans stopped;
// peaks, speeds and noise are taken over hours 2..6 (the regime the configuration settles into).
//
// Cost = noise + penalty. Noise: sum over scenarios of weight x profile noise x fan noise (loud x
// (rpm/1000)^2; a start counts like 0.3 h at 1000 rpm); weights mean 1, high load and warm room 0.5 -
// every use mode counts as its profile's noise weight says, not by the minutes it happened to fill.
// Penalty: 5 x (peak - target)^2 per sensor over its target (not in the warm room: above target on a
// hot day is expected, only warn counts there), plus 200 + 100/C for a sensor at warn. Only models
// validated in the scenario's mode count (sens_trusted): an unreliable model never drives the fans.
#include "learn.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define SIM_H     6.0
#define SIM_FROM  2.0

static int md_prof(int md) { return md == MD_RUHE ? P_RUHE : md == MD_PLAY ? P_PLAYBACK : P_IDLE; }
static int cmpd(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }

int scenarios(scen_t *out, const series_t *d, const cfg_t *c) {
  int nsc = 0; double mins[3] = { 0 };
  static const int use[3] = { MD_RUHE, MD_IDLE, MD_PLAY };
  double *load = malloc((size_t)(d->n ? d->n : 1) * sizeof *load);
  if (!load) return 0;
  for (int i = 0; i < d->n; i++) { int md = bin_mode(&d->b[i]); if (md >= 0 && md < MD_TEST && bin_inputs(&d->b[i], c)) mins[md]++; }
  for (int u = 0; u < 3; u++) {
    int md = use[u];
    if (mins[md] < 120) continue;
    int nl = 0;
    for (int i = 0; i < d->n; i++) if (bin_mode(&d->b[i]) == md && bin_inputs(&d->b[i], c)) load[nl++] = d->b[i].pc + d->b[i].pg + d->b[i].pr;
    qsort(load, (size_t)nl, sizeof *load, cmpd);
    double thr = load[(nl * 9) / 10];
    for (int kind = 0; kind < 2; kind++) {
      scen_t s; memset(&s, 0, sizeof s);
      double n = 0, nv = 0;
      for (int i = 0; i < d->n; i++) {
        const bin_t *b = &d->b[i];
        if (bin_mode(b) != md || !bin_inputs(b, c)) continue;
        if (kind == 1 && b->pc + b->pg + b->pr < thr) continue;
        s.pc += b->pc; s.pg += b->pg; s.pr += b->pr; s.amb += b->amb;
        s.cpu += isnan(b->cpu) ? 0 : b->cpu; s.gpu += isnan(b->gpu) ? 0 : b->gpu;
        if (!isnan(b->vol)) { s.vol += b->vol; nv++; }
        n++;
      }
      if (n < 10) continue;
      s.pc /= n; s.pg /= n; s.pr /= n; s.amb /= n; s.cpu /= n; s.gpu /= n;
      s.vol = nv > 0 ? s.vol / nv : 0.5;
      s.prof = md_prof(md); s.md = md; s.minutes = n;
      if (kind == 0) {
        snprintf(s.name, sizeof s.name, "%s mean", mode_label[md]); s.weight = 1; out[nsc++] = s;
        scen_t w = s; snprintf(w.name, sizeof w.name, "%s warm room +5", mode_label[md]); w.amb += 5; w.weight = 0.5; out[nsc++] = w;
      } else { snprintf(s.name, sizeof s.name, "%s high load", mode_label[md]); s.weight = 0.5; out[nsc++] = s; }
      if (nsc >= MAX_SCEN - 1) break;
    }
  }
  free(load);
  return nsc;
}

void simulate(const cfg_t *c, const model_t *m, const scen_t *sc, int hot, simres_t *r) {
  memset(r, 0, sizeof *r);
  double T[MAX_SENS]; int live[MAX_SENS];
  for (int s = 0; s < c->nsens; s++) {
    const smodel_t *sm = &m->s[s];
    live[s] = sm->ok && !sm->fixed;
    if (sm->fixed) T[s] = sc->amb;
    else if (live[s]) T[s] = sc->amb + (hot ? sm->steady_hi + 2 : sm->steady_lo);
    else T[s] = sc->amb + sm->steady_hi;                    // no model: held at its usual high
    r->peak[s] = -1e9;
  }
  fanstate_t fs[MAX_FANS]; double rpm[MAX_FANS] = { 0 };
  for (int n = 0; n < MAX_FANS; n++) { fs[n].out = 0; fs[n].on_since = fs[n].off_since = -1e9; }
  double shift = c->prof[sc->prof].base + c->prof[sc->prof].vol * sc->vol;
  double t = 0, end = SIM_H * 3600, from = SIM_FROM * 3600, span = end - from, dt = 10;
  while (t < end) {
    int moving = 0;
    for (int n = 0; n < m->nfans; n++) {
      if (!c->fan[n].used) { rpm[n] = 0; continue; }
      fanstep_t st; policy_fan(c, n, T, sc->cpu, sc->gpu, shift, t, dt, -1, &fs[n], &st);
      rpm[n] = fs[n].out; moving |= st.moving;
      if (t >= from && st.started) r->starts[n]++;
    }
    for (int s = 0; s < c->nsens; s++)
      if (live[s]) T[s] += model_rate(&m->s[s], m->nfans, T[s], sc->amb, sc->pc, sc->pg, sc->pr, rpm) * dt / 60;
    if (t >= from) {
      for (int s = 0; s < c->nsens; s++) if (T[s] > r->peak[s]) r->peak[s] = T[s];
      for (int n = 0; n < m->nfans; n++) { r->rpm[n] += rpm[n] * dt / span; if (rpm[n] > 0) r->on[n] += dt / span; }
      r->noise += fan_noise(c, rpm) * dt / span;
    }
    t += dt;
    dt = moving ? DT_FAST : 10;
  }
  for (int n = 0; n < m->nfans; n++) if (c->fan[n].used) r->noise += 0.3 * c->fan[n].loud * r->starts[n] / (span / 3600);
}

double cost(const cfg_t *c, const model_t *m, const scen_t *sc, int nsc, simres_t *res, double *penalty) {
  double total = 0, pen = 0;
  for (int i = 0; i < nsc; i++) {
    simres_t a, b; simulate(c, m, &sc[i], 0, &a); simulate(c, m, &sc[i], 1, &b);
    simres_t r = a;
    r.noise = (a.noise + b.noise) / 2;
    for (int n = 0; n < MAX_FANS; n++) { r.rpm[n] = (a.rpm[n] + b.rpm[n]) / 2; r.on[n] = (a.on[n] + b.on[n]) / 2; r.starts[n] = (a.starts[n] + b.starts[n]) / 2; }
    for (int s = 0; s < c->nsens; s++) r.peak[s] = fmax(a.peak[s], b.peak[s]);
    total += sc[i].weight * c->prof[sc[i].prof].noise * r.noise;
    int warm = strstr(sc[i].name, "warm") != NULL;
    for (int s = 0; s < c->nsens; s++) {
      if (!sens_trusted(m, c, s, sc[i].md)) continue;           // an unvalidated model drives nothing
      double over = r.peak[s] - c->sens[s].target;
      if (over > 0 && !warm) pen += 5 * over * over;             // a hot day: only warn counts
      double hot = r.peak[s] - c->sens[s].warn;
      if (hot > 0) pen += 200 + 100 * hot;
    }
    if (res) res[i] = r;
  }
  if (penalty) *penalty = pen;
  return total + pen;
}
