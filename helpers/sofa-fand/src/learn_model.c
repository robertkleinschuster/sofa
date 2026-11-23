// Grey-box thermal model per sensor, fitted on one-minute bins:
//
//   dT/dt [C/min] = a0 + h_cpu*Pc/10 + h_gpu*Pg/10 + h_rest*Pr/10 - (k0 + sum_f k_f*rpm_f/1000)*(T - Tamb)
//
// Heat in from the measured power (CPU package, GPU, the rest of the machine), heat out through the
// case (k0) and through every fan's air flow (k_f, proportional to its speed). Non-negative least
// squares (a0 free), so the physics keeps its signs: power heats, fans cool.
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

static int npar(int nfans) { return 5 + nfans; }

static void features(const bin_t *b, double T, int nfans, double *x) {
  double dT = T - b->amb;
  x[0] = 1; x[1] = b->pc / 10; x[2] = b->pg / 10; x[3] = b->pr / 10; x[4] = -dT;
  for (int f = 0; f < nfans; f++) x[5 + f] = -(isnan(b->fan[f]) ? 0 : b->fan[f] / 1000) * dT;
}

double model_rate(const smodel_t *s, int nfans, double T, double amb, double pc, double pg, double pr, const double *rpm) {
  double k = s->th[4];
  for (int f = 0; f < nfans; f++) k += s->th[5 + f] * rpm[f] / 1000;
  return s->th[0] + s->th[1] * pc / 10 + s->th[2] * pg / 10 + s->th[3] * pr / 10 - k * (T - amb);
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

void model_fit(model_t *m, const series_t *d, const cfg_t *c, const machine_t *mc) {
  memset(m, 0, sizeof *m);
  int nf = 0; for (int f = 0; f < MAX_FANS; f++) if (c->fan[f].used) nf = f + 1;
  m->nfans = nf;
  int np = npar(nf);
  if (d->n < 2) return;
  double t0 = d->b[0].t;
  int nch = (int)((d->b[d->n - 1].t - t0) / CHUNK) + 1;
  double *Gc = calloc((size_t)nch * np * np, sizeof *Gc), *bc = calloc((size_t)nch * np, sizeof *bc);
  int *nc = calloc((size_t)nch, sizeof *nc);
  double *errs = malloc((size_t)d->n * sizeof *errs), *lev = malloc((size_t)d->n * sizeof *lev);
  if (!Gc || !bc || !nc || !errs || !lev) goto out;
  int amb_si = ambient_index(c, mc);
  for (int s = 0; s < c->nsens; s++) {
    smodel_t *sm = &m->s[s];
    if (s == amb_si) { sm->ok = sm->fixed = 1; continue; }
    memset(Gc, 0, (size_t)nch * np * np * sizeof *Gc); memset(bc, 0, (size_t)nch * np * sizeof *bc); memset(nc, 0, (size_t)nch * sizeof *nc);
    double G[NPAR * NPAR] = { 0 }, b[NPAR] = { 0 }, x[NPAR];
    int nlev = 0;
    for (int i = 0; i < d->n; i++) {
      const bin_t *bi = &d->b[i];
      if (isnan(bi->temp[s]) || !bin_inputs(bi, c)) continue;
      if (bi->curve && !bi->test) lev[nlev++] = bi->temp[s] - bi->amb;
      if (!bin_next(d, i) || isnan(d->b[i + 1].temp[s])) continue;
      double y = d->b[i + 1].temp[s] - bi->temp[s];
      features(bi, bi->temp[s], nf, x);
      int ch = (int)((bi->t - t0) / CHUNK);
      for (int j = 0; j < np; j++) {
        bc[ch * np + j] += x[j] * y;
        for (int k = 0; k < np; k++) Gc[(ch * np + j) * np + k] += x[j] * x[k];
      }
      nc[ch]++; sm->npts++;
    }
    if (nlev > 10) { qsort(lev, (size_t)nlev, sizeof *lev, cmpd); sm->steady_lo = lev[nlev / 10]; sm->steady_hi = lev[(nlev * 95) / 100]; }
    if (sm->npts < 600) continue;                              // < 10 h of usable minutes
    for (int ch = 0; ch < nch; ch++) for (int j = 0; j < np; j++) { b[j] += bc[ch * np + j]; for (int k = 0; k < np; k++) G[j * np + k] += Gc[(ch * np + j) * np + k]; }
    solve(G, b, np, sm->th);
    // free-run validation, chunk by chunk
    double se[MODE_N] = { 0 }, sall = 0; int nerr = 0;
    int i = 0;
    for (int ch = 0; ch < nch; ch++) {
      while (i < d->n && (int)((d->b[i].t - t0) / CHUNK) < ch) i++;
      if (nc[ch] < 60) continue;
      double Gh[NPAR * NPAR], bh[NPAR]; smodel_t held = *sm;
      for (int j = 0; j < np; j++) { bh[j] = b[j] - bc[ch * np + j]; for (int k = 0; k < np; k++) Gh[j * np + k] = G[j * np + k] - Gc[(ch * np + j) * np + k]; }
      solve(Gh, bh, np, held.th);
      int run = 0; double T = 0;
      for (int k = i; k < d->n && (int)((d->b[k].t - t0) / CHUNK) == ch; k++) {
        const bin_t *bk = &d->b[k];
        if (!bin_inputs(bk, c)) { run = 0; continue; }
        if (!isnan(bk->temp[s])) {
          if (!run) { T = bk->temp[s]; run = 1; }
          else {
            double e = T - bk->temp[s]; int md = bin_mode(bk);
            if (md >= 0) { se[md] += e * e; sm->vmin[md]++; }
            sall += e * e; errs[nerr++] = fabs(e);
          }
        }
        if (!run) continue;
        if (!bin_next(d, k)) { run = 0; continue; }
        T += model_rate(&held, nf, T, bk->amb, bk->pc, bk->pg, bk->pr, bk->fan);
        if (T < -20 || T > 150) run = 0;                       // diverged: counts via the errors so far
      }
    }
    for (int md = 0; md < MODE_N; md++) sm->rmse[md] = sm->vmin[md] > 0 ? sqrt(se[md] / sm->vmin[md]) : NAN;
    if (nerr < 240) continue;
    sm->rmse_all = sqrt(sall / nerr);
    qsort(errs, (size_t)nerr, sizeof *errs, cmpd);
    sm->err90 = errs[(nerr * 9) / 10]; sm->errmax = errs[nerr - 1];
    sm->ok = isfinite(sm->rmse_all);
  }
out:
  free(Gc); free(bc); free(nc); free(errs); free(lev);
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
