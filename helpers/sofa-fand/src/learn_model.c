// Grey-box thermal model per sensor, fitted on one-minute bins:
//
//   T = N + r_gpu*Pg + r_cpu*Pc
//   dN/dt [C/min] = a0 + h_cpu*Pc/10 + h_gpu*Pg/10 + h_rest*Pr/10 + sum_f q_f*[fan f runs]
//                   - (k0 + sum_f k_f*rpm_f/1000)*(N - Tamb)
//
// N is the slow node (heat sink, board): heat in from the measured power (CPU package, GPU, the rest of
// the machine), heat out through the case (k0) and through every fan's air flow (k_f, proportional to
// its speed). Non-negative least squares (a0 free), so the physics keeps its signs: power heats, fans
// cool. A sensor on a die also follows its chip's power at once (die to heat sink, seconds - well
// inside a minute): the instant offset r*P. Without it a die sensor's fast drop when playback ends
// (GPU 15 -> 5 W: TG0D 9 C in 5 min, the heat sink 4 C) cannot be followed (2026-11-25: TG0D free-run
// error in idle 2.9 C -> 1.9 C). Board sensors get worse with it - so r is chosen per sensor, from a
// grid, by the same held-out validation; 0 is a valid answer.
//
// Fan air (q_f): a fan's air does not reach every sensor at the ambient reading - on its way it has
// passed other heat sources (a heat sink, the board) whose heat Q it carries. Its temperature there is
// Tamb + Q/(c*rpm), so the exchange k*rpm*(Tair - N) = -k*rpm*(N - Tamb) + k*Q/c: the cooling term plus
// a constant heat input while the fan runs, whatever its speed. Without it a sensor downstream of a
// warm stream is cooled far too much at low speed and too little at high speed (2026-11-26: Tp3H, CPU
// fan at ~500 rpm in the identification block: measured -3.8 C, model -7 C; in playback at ~1800 rpm
// the model 6 C too warm; free-run error in playback 2.09 -> 1.48 C, in the identification 2.80 -> 1.50).
// Other sensors fit worse with the extra terms (TPCD in playback 1.74 -> 2.28), so whether a sensor
// gets them is again the validation's choice.
//
// Validation is what the simulator does: a free run (the model integrates its own temperature from
// a measured start, driven only by the measured inputs) over every held-out 2 h chunk, with the model
// fitted on everything else. Held-out fits are cheap: the chunk's share of the normal equations is
// subtracted from the total. The error is reported per mode (rest, in use, playback, test).
#include "learn.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define CHUNK 7200.0

static int npar(int nfans) { return 5 + 2 * nfans; }

static void features(const bin_t *b, double N, int nfans, int air, double *x) {
  double dT = N - b->amb;
  x[0] = 1; x[1] = b->pc / 10; x[2] = b->pg / 10; x[3] = b->pr / 10; x[4] = -dT;
  for (int f = 0; f < nfans; f++) x[5 + f] = -(isnan(b->fan[f]) ? 0 : b->fan[f] / 1000) * dT;
  for (int f = 0; f < nfans; f++) x[5 + nfans + f] = air && !isnan(b->fan[f]) && b->fan[f] > 0;   // 0: th stays 0
}

double model_offset(const smodel_t *s, double pc, double pg) { return s->rg * pg + s->rc * pc; }

double model_rate(const smodel_t *s, int nfans, double N, double amb, double pc, double pg, double pr, const double *rpm) {
  double k = s->th[4];
  for (int f = 0; f < nfans; f++) k += s->th[5 + f] * rpm[f] / 1000;
  double q = 0;
  for (int f = 0; f < nfans; f++) if (rpm[f] > 0) q += s->th[5 + nfans + f];
  return s->th[0] + s->th[1] * pc / 10 + s->th[2] * pg / 10 + s->th[3] * pr / 10 + q - k * (N - amb);
}

// min 0.5 th'G th - b'th, th[j] >= 0 for j >= 1 (projected coordinate descent, small ridge)
static void solve(const double *G, const double *b, int np, double *th) {
  double d[NPAR];
  for (int j = 0; j < np; j++) { d[j] = G[j * np + j] * 1.0001 + 1e-9; th[j] = 0; }
  for (int it = 0; it < 400; it++) {
    double moved = 0;
    for (int j = 0; j < np; j++) {
      double r = b[j];
      for (int k = 0; k < np; k++) if (k != j) r -= G[j * np + k] * th[k];
      double v = r / d[j];
      if (j >= 1 && v < 0) v = 0;
      moved = fmax(moved, fabs(v - th[j]) * sqrt(d[j]));
      th[j] = v;
    }
    if (moved < 1e-7) break;
  }
}

static int cmpd(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }

static int ambient_index(const cfg_t *c, const machine_t *mc) {
  return mc && mc->ambient[0] ? sens_index(c, mc->ambient) : -1;
}

// workspace of one sensor's fit: the normal equations per 2 h chunk
typedef struct { int nch, np, nf; double t0; double *Gc, *bc; int *nc; double *errs; } fitws_t;

// fit and validate sensor s with the instant offsets sm->rg / sm->rc; the score the offsets are chosen
// by: the mean of the use modes' squared free-run errors (each mode must be right on its own - the
// gate checks them one by one), INFINITY if it cannot be validated
static double fit_sensor(smodel_t *sm, int s, const series_t *d, const cfg_t *c, fitws_t *w) {
  int np = w->np, nf = w->nf, nch = w->nch;
  memset(w->Gc, 0, (size_t)nch * np * np * sizeof *w->Gc); memset(w->bc, 0, (size_t)nch * np * sizeof *w->bc); memset(w->nc, 0, (size_t)nch * sizeof *w->nc);
  memset(sm->th, 0, sizeof sm->th); memset(sm->rmse, 0, sizeof sm->rmse); memset(sm->vmin, 0, sizeof sm->vmin);
  sm->npts = 0; sm->ok = 0; sm->rmse_all = sm->err90 = sm->errmax = 0;
  double G[NPAR * NPAR] = { 0 }, b[NPAR] = { 0 }, x[NPAR];
  #define NODE(bin) ((bin)->temp[s] - model_offset(sm, (bin)->pc, (bin)->pg))
  for (int i = 0; i < d->n; i++) {
    const bin_t *bi = &d->b[i];
    if (isnan(bi->temp[s]) || !bin_inputs(bi, c)) continue;
    if (!bin_next(d, i) || isnan(d->b[i + 1].temp[s]) || !bin_inputs(&d->b[i + 1], c)) continue;
    double y = NODE(&d->b[i + 1]) - NODE(bi);
    features(bi, NODE(bi), nf, sm->air, x);
    int ch = (int)((bi->t - w->t0) / CHUNK);
    for (int j = 0; j < np; j++) {
      w->bc[ch * np + j] += x[j] * y;
      for (int k = 0; k < np; k++) w->Gc[(ch * np + j) * np + k] += x[j] * x[k];
    }
    w->nc[ch]++; sm->npts++;
  }
  if (sm->npts < 600) return INFINITY;                         // < 10 h of usable minutes
  for (int ch = 0; ch < nch; ch++) for (int j = 0; j < np; j++) { b[j] += w->bc[ch * np + j]; for (int k = 0; k < np; k++) G[j * np + k] += w->Gc[(ch * np + j) * np + k]; }
  solve(G, b, np, sm->th);
  // free-run validation, chunk by chunk: the node runs free, the sensor is node + offset
  double se[MODE_N] = { 0 }, sall = 0; int nerr = 0;
  int i = 0;
  for (int ch = 0; ch < nch; ch++) {
    while (i < d->n && (int)((d->b[i].t - w->t0) / CHUNK) < ch) i++;
    if (w->nc[ch] < 60) continue;
    double Gh[NPAR * NPAR], bh[NPAR]; smodel_t held = *sm;
    for (int j = 0; j < np; j++) { bh[j] = b[j] - w->bc[ch * np + j]; for (int k = 0; k < np; k++) Gh[j * np + k] = G[j * np + k] - w->Gc[(ch * np + j) * np + k]; }
    solve(Gh, bh, np, held.th);
    int run = 0; double N = 0;
    for (int k = i; k < d->n && (int)((d->b[k].t - w->t0) / CHUNK) == ch; k++) {
      const bin_t *bk = &d->b[k];
      if (!bin_inputs(bk, c)) { run = 0; continue; }
      if (!isnan(bk->temp[s])) {
        if (!run) { N = NODE(bk); run = 1; }
        else {
          double e = N + model_offset(sm, bk->pc, bk->pg) - bk->temp[s]; int md = bin_mode(bk);
          if (md >= 0) { se[md] += e * e; sm->vmin[md]++; }
          sall += e * e; w->errs[nerr++] = fabs(e);
        }
      }
      if (!run) continue;
      if (!bin_next(d, k)) { run = 0; continue; }
      N += model_rate(&held, nf, N, bk->amb, bk->pc, bk->pg, bk->pr, bk->fan);
      if (N < -20 || N > 150) run = 0;                         // diverged: counts via the errors so far
    }
  }
  #undef NODE
  for (int md = 0; md < MODE_N; md++) sm->rmse[md] = sm->vmin[md] > 0 ? sqrt(se[md] / sm->vmin[md]) : NAN;
  if (nerr < 240) return INFINITY;
  sm->rmse_all = sqrt(sall / nerr);
  qsort(w->errs, (size_t)nerr, sizeof *w->errs, cmpd);
  sm->err90 = w->errs[(nerr * 9) / 10]; sm->errmax = w->errs[nerr - 1];
  sm->ok = isfinite(sm->rmse_all);
  if (!sm->ok) return INFINITY;
  static const int use[] = { MD_RUHE, MD_IDLE, MD_PLAY };
  double score = 0; int nm = 0;
  for (int u = 0; u < 3; u++) if (sm->vmin[use[u]] >= 30) { score += sm->rmse[use[u]] * sm->rmse[use[u]]; nm++; }
  return nm ? score / nm : sm->rmse_all * sm->rmse_all;
}

void model_fit(model_t *m, const series_t *d, const cfg_t *c, const machine_t *mc) {
  memset(m, 0, sizeof *m);
  int nf = 0; for (int f = 0; f < MAX_FANS; f++) if (c->fan[f].used) nf = f + 1;
  m->nfans = nf;
  if (d->n < 2) return;
  fitws_t w = { .np = npar(nf), .nf = nf, .t0 = d->b[0].t };
  w.nch = (int)((d->b[d->n - 1].t - w.t0) / CHUNK) + 1;
  int np = w.np, nch = w.nch;
  w.Gc = calloc((size_t)nch * np * np, sizeof *w.Gc); w.bc = calloc((size_t)nch * np, sizeof *w.bc);
  w.nc = calloc((size_t)nch, sizeof *w.nc); w.errs = malloc((size_t)d->n * sizeof *w.errs);
  double *lev = malloc((size_t)d->n * sizeof *lev);
  if (!w.Gc || !w.bc || !w.nc || !w.errs || !lev) goto out;
  int amb_si = ambient_index(c, mc);
  for (int s = 0; s < c->nsens; s++) {
    smodel_t *sm = &m->s[s];
    if (s == amb_si) { sm->ok = sm->fixed = 1; continue; }
    int nlev = 0;
    for (int i = 0; i < d->n; i++) {
      const bin_t *bi = &d->b[i];
      if (!isnan(bi->temp[s]) && bin_inputs(bi, c) && bi->curve && !bi->test) lev[nlev++] = bi->temp[s] - bi->amb;
    }
    // the model's shape is chosen by the validation: without and with the fan-air terms, each with
    // the instant offsets from a coarse grid, then its neighbourhood (C/W); the simpler shape wins ties
    double best = INFINITY, brg = 0, brc = 0; int bair = 0;
    for (int air = 0; air < 2; air++) {
      double ag = 0, ac = 0, abest = INFINITY;
      sm->air = air;
      for (int pass = 0; pass < 2; pass++) {
        double step = pass ? R_STEP / 2 : R_STEP, cg = ag, cc = ac;
        int lo = pass ? -1 : 0, hi = pass ? 1 : (int)(R_MAX / R_STEP + 0.5);
        for (int ig = lo; ig <= hi; ig++) for (int ic = lo; ic <= hi; ic++) {
          double rg = pass ? cg + ig * step : ig * step, rc = pass ? cc + ic * step : ic * step;
          if (rg < 0 || rc < 0 || rg > R_MAX || rc > R_MAX || (pass && !ig && !ic)) continue;
          sm->rg = rg; sm->rc = rc;
          double sc = fit_sensor(sm, s, d, c, &w);
          if (sc < abest - 1e-9) { abest = sc; ag = rg; ac = rc; }
        }
      }
      if (abest < best - 1e-9) { best = abest; brg = ag; brc = ac; bair = air; }
    }
    sm->rg = brg; sm->rc = brc; sm->air = bair;
    fit_sensor(sm, s, d, c, &w);
    if (nlev > 10) { qsort(lev, (size_t)nlev, sizeof *lev, cmpd); sm->steady_lo = lev[nlev / 10]; sm->steady_hi = lev[(nlev * 95) / 100]; }
  }
out:
  free(w.Gc); free(w.bc); free(w.nc); free(w.errs); free(lev);
}

double gate_rmse(const cfg_t *c, int si) {
  ff_t f = c->sens[si].ff;
  return f == FF_CPU || f == FF_BOTH ? 3.0 : 2.0;   // load-driven sensors jump with every burst
}

int sensor_steers(const cfg_t *c, int si) {
  for (int n = 0; n < MAX_FANS; n++) {
    if (!c->fan[n].used) continue;
    for (int k = 0; k < c->fan[n].ncurves; k++) if (c->fan[n].curves[k].sensor == si) return 1;
    for (int k = 0; k < c->fan[n].nfloors; k++) if (c->fan[n].floors[k].sensor == si) return 1;
  }
  return 0;
}

int sens_trusted(const model_t *m, const cfg_t *c, int s, int md) {
  const smodel_t *sm = &m->s[s];
  return sm->ok && !sm->fixed && md >= 0 && md < MODE_N && sm->vmin[md] >= 120 && sm->rmse[md] <= gate_rmse(c, s);
}

int model_trusted(const model_t *m, const cfg_t *c, char *why, size_t cap) {
  static const int use[] = { MD_RUHE, MD_IDLE, MD_PLAY };
  for (int s = 0; s < c->nsens; s++) {
    if (!sensor_steers(c, s) || m->s[s].fixed) continue;
    const smodel_t *sm = &m->s[s];
    if (!sm->ok) { snprintf(why, cap, "%s: no validated model (%d usable minutes)", c->sens[s].key, sm->npts); return 0; }
    for (int u = 0; u < 3; u++) {
      int md = use[u];
      if (sm->vmin[md] < 120) { snprintf(why, cap, "%s: only %.0f validated minutes in %s", c->sens[s].key, sm->vmin[md], mode_label[md]); return 0; }
      if (sm->rmse[md] > gate_rmse(c, s)) { snprintf(why, cap, "%s: free-run error %.2f C in %s > %.1f", c->sens[s].key, sm->rmse[md], mode_label[md], gate_rmse(c, s)); return 0; }
    }
  }
  why[0] = 0;
  return 1;
}
