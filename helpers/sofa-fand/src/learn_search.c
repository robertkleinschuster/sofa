// The next step: greedy descent - the single best move per round, at most MAX_CHANGES parameters -
// over the learned layer's parameters (shift of every reference curve, base shift of every used
// profile) on a 0.5 C grid, inside tonight's box around the current values (curves +-2 C, profiles
// +-1 C) and inside the layer's safety rules (learned_check - the daemon's own check). Moves that
// make anything quieter need a model validated in every use mode (model_trusted); moves rejected by
// a trial within 14 days are not tried again. A candidate that pushes a sensor over its target in a
// scenario where the current configuration keeps it below is refused outright (sensors whose model
// is validated in that mode). The step is taken only if it lowers the cost by >= 2 % (and 0.05),
// a cooler step lowers the temperature penalty, a quieter or mixed one (a quieter move with a
// compensating cooler one) the noise.
// For the report, the same descent then runs without the box or the limit: where it is heading.
#include "learn.h"
#include <math.h>
#include <string.h>

typedef struct { int fan, k, prof; double lo, hi; char key[24]; } par_t;   // prof >= 0: profile base, else curve shift
#define MAX_PAR (MAX_FANS * MAX_CURVES + P_COUNT)
#define MAX_CHANGES 3      // parameters one step may move (a rolled-back step blocks each of them)

static double get(const cfg_t *c, const par_t *p) { return p->prof >= 0 ? c->prof[p->prof].base : c->fan[p->fan].curves[p->k].shift; }
static void set(cfg_t *c, const par_t *p, double v) { if (p->prof >= 0) c->prof[p->prof].base = v; else c->fan[p->fan].curves[p->k].shift = v; }

typedef struct {
  const cfg_t *ref; const model_t *m; const scen_t *sc; int nsc;
  simres_t base[MAX_SCEN];       // the current configuration's results (target guard)
  int evals;
} ctx_t;

static double eval(ctx_t *x, const cfg_t *c) {
  char e[200]; if (learned_check(c, x->ref, e, sizeof e)) return INFINITY;
  simres_t r[MAX_SCEN]; double z = cost(c, x->m, x->sc, x->nsc, r, NULL); x->evals++;
  for (int i = 0; i < x->nsc; i++) {
    if (strstr(x->sc[i].name, "warm")) continue;
    for (int s = 0; s < c->nsens; s++) {
      if (!sens_trusted(x->m, c, s, x->sc[i].md)) continue;
      double tg = c->sens[s].target;
      if (r[i].peak[s] > tg + 0.05 && x->base[i].peak[s] <= tg) return INFINITY;
    }
  }
  return z;
}

static void descend(ctx_t *x, cfg_t *c, double *z, par_t *ps, int np, double box_curve, double box_prof, const cfg_t *cur, int quiet_ok, int max_changes) {
  for (int round = 0; round < 4 * np; round++) {      // greedy: the single best move per round
    int changed = 0;
    for (int i = 0; i < np; i++) if (fabs(get(c, &ps[i]) - get(cur, &ps[i])) > 1e-9) changed++;
    int bi = -1; double bv = 0, bz = *z;
    for (int i = 0; i < np; i++) {
      const par_t *p = &ps[i];
      double v0 = get(cur, p), vc = get(c, p), box = p->prof >= 0 ? box_prof : box_curve;
      if (changed >= max_changes && fabs(vc - v0) < 1e-9) continue;   // full: only refine what moved
      double lo = fmax(p->lo, v0 - box), hi = fmin(p->hi, v0 + box);
      if (!quiet_ok && hi > v0) hi = v0;
      for (double v = ceil(lo * 2) / 2; v <= hi + 1e-9; v += 0.5) {
        if (fabs(v - vc) < 1e-9) continue;
        char k[32]; snprintf(k, sizeof k, "%s/%c", p->key, v > v0 ? '+' : '-');
        if (fabs(v - v0) > 1e-9 && rejected_recently(k)) continue;
        cfg_t t = *c; set(&t, p, v);
        double zz = eval(x, &t);
        if (zz < bz - 1e-6) { bz = zz; bi = i; bv = v; }
      }
    }
    if (bi < 0) break;
    set(c, &ps[bi], bv); *z = bz;
  }
}

static int params(par_t *ps, const cfg_t *cur, const cfg_t *ref, const model_t *m, const scen_t *sc, int nsc) {
  int np = 0;
  for (int n = 0; n < MAX_FANS; n++) {
    if (!cur->fan[n].used) continue;
    for (int k = 0; k < ref->fan[n].ncurves; k++) {
      int s = cur->fan[n].curves[k].sensor;
      if (!m->s[s].ok || m->s[s].fixed) continue;              // a sensor without a model: its curves stay
      par_t *p = &ps[np++]; p->fan = n; p->k = k; p->prof = -1; p->lo = -MAX_SHIFT; p->hi = MAX_SHIFT;
      snprintf(p->key, sizeof p->key, "f%d/%s", n, cur->sens[s].key);
    }
  }
  for (int pr = 0; pr < P_COUNT; pr++) {
    int used = 0; for (int i = 0; i < nsc; i++) if (sc[i].prof == pr) used = 1;
    if (!used) continue;
    par_t *p = &ps[np++]; p->fan = -1; p->k = -1; p->prof = pr; p->lo = -MAX_SHIFT; p->hi = MAX_SHIFT;
    if (ref->prof[pr].learn == LEARN_COOLER) p->hi = ref->prof[pr].base;
    snprintf(p->key, sizeof p->key, "p/%s", prof_name[pr]);
  }
  return np;
}

static void report_results(FILE *rep, const char *title, const cfg_t *c, const model_t *m, const scen_t *sc, int nsc) {
  simres_t r[MAX_SCEN]; double pen, z = cost(c, m, sc, nsc, r, &pen);
  fprintf(rep, "\n### %s (cost %.2f = noise %.2f + temperature penalty %.2f)\n\n| scenario | noise |", title, z, z - pen, pen);
  for (int n = 0; n < m->nfans; n++) if (c->fan[n].used) fprintf(rep, " %s rpm (on) |", c->fan[n].name);
  fprintf(rep, " sensors over target / near warn |\n|---|---|");
  for (int n = 0; n < m->nfans; n++) if (c->fan[n].used) fprintf(rep, "---|");
  fprintf(rep, "---|\n");
  for (int i = 0; i < nsc; i++) {
    fprintf(rep, "| %s | %.2f |", sc[i].name, r[i].noise);
    for (int n = 0; n < m->nfans; n++) if (c->fan[n].used) fprintf(rep, " %.0f (%.0f %%) |", r[i].rpm[n], 100 * r[i].on[n]);
    int any = 0;
    for (int s = 0; s < c->nsens; s++) {
      if (!sens_trusted(m, c, s, sc[i].md) || r[i].peak[s] <= c->sens[s].target) continue;
      fprintf(rep, "%s %s %.1f/%.0f%s", any ? "," : "", c->sens[s].key, r[i].peak[s], c->sens[s].target, r[i].peak[s] > c->sens[s].warn ? " AT WARN" : "");
      any = 1;
    }
    fprintf(rep, "%s |\n", any ? "" : " -");
  }
}

void search_step(step_t *st, const cfg_t *cur, const cfg_t *ref, const model_t *m, const scen_t *sc, int nsc, FILE *rep) {
  memset(st, 0, sizeof *st);
  st->eff = *cur;
  if (!nsc) { snprintf(st->why, sizeof st->why, "no scenario (less than 2 h of data in every use mode)"); return; }
  static ctx_t x; memset(&x, 0, sizeof x); x.ref = ref; x.m = m; x.sc = sc; x.nsc = nsc;
  st->cost_now = cost(cur, m, sc, nsc, x.base, &st->pen_now);
  char why[200]; int quiet_ok = model_trusted(m, cur, why, sizeof why);
  par_t ps[MAX_PAR]; int np = params(ps, cur, ref, m, sc, nsc);
  if (rep) {
    fprintf(rep, "\n## Search\n\n%d parameters; quieter moves %s%s%s.\n", np, quiet_ok ? "allowed" : "NOT allowed (", quiet_ok ? "" : why, quiet_ok ? "" : ")");
    report_results(rep, "Current configuration, simulated", cur, m, sc, nsc);
  }
  cfg_t c = *cur; double z = st->cost_now;
  descend(&x, &c, &z, ps, np, 2.0, 1.0, cur, quiet_ok, MAX_CHANGES);
  st->eff = c; st->cost_step = cost(&c, m, sc, nsc, NULL, &st->pen_step);
  // the step in words
  size_t o = 0, ko = 0; int quieter = 0, cooler = 0;
  for (int i = 0; i < np; i++) {
    double a = get(cur, &ps[i]), b = get(&c, &ps[i]);
    if (fabs(a - b) < 1e-9) continue;
    if (b > a) quieter = 1; else cooler = 1;
    int w = ps[i].prof >= 0
      ? snprintf(st->text + o, sizeof st->text - o, "%sprofile %s %+.1f -> %+.1f", o ? "; " : "", prof_name[ps[i].prof], a, b)
      : snprintf(st->text + o, sizeof st->text - o, "%sfan %d %s curve shift %+.1f -> %+.1f", o ? "; " : "", ps[i].fan, cur->sens[cur->fan[ps[i].fan].curves[ps[i].k].sensor].key, a, b);
    if (w > 0 && (size_t)w < sizeof st->text - o) o += (size_t)w;
    w = snprintf(st->keys + ko, sizeof st->keys - ko, "%s%s/%c", ko ? " " : "", ps[i].key, b > a ? '+' : '-');
    if (w > 0 && (size_t)w < sizeof st->keys - ko) ko += (size_t)w;
  }
  snprintf(st->kind, sizeof st->kind, "%s", quieter && cooler ? "mixed" : quieter ? "quieter" : "cooler");
  // where it is heading (report only)
  cfg_t far = c; double zf = z;
  descend(&x, &far, &zf, ps, np, 2 * MAX_SHIFT, 2 * MAX_SHIFT, cur, quiet_ok, np);
  st->cost_best = zf;
  if (rep) {
    if (o) report_results(rep, "With the step", &c, m, sc, nsc);
    fprintf(rep, "\nWithout tonight's limits the search would go to cost %.2f:", zf);
    int any = 0;
    for (int i = 0; i < np; i++) { double a = get(cur, &ps[i]), b = get(&far, &ps[i]); if (fabs(a - b) > 1e-9) { fprintf(rep, "%s %s %+.1f", any ? "," : "", ps[i].key, b); any = 1; } }
    fprintf(rep, "%s (%d simulations).\n", any ? "" : " nowhere else", x.evals);
  }
  if (!o) { snprintf(st->why, sizeof st->why, "no step lowers the cost (%.2f)%s%s", st->cost_now, quiet_ok ? "" : "; quieter moves not allowed: ", quiet_ok ? "" : why); return; }
  double gain = st->cost_now - st->cost_step;
  if (gain < fmax(0.02 * st->cost_now, 0.05)) { snprintf(st->why, sizeof st->why, "best step (%s) gains only %.3f of %.2f", st->text, gain, st->cost_now); return; }
  // the gain must come from the part the step is about - else it is a simulation artefact
  // (hysteresis paths), not a reason to change the fans
  if (cooler && !quieter && st->pen_step > st->pen_now - 0.01) { snprintf(st->why, sizeof st->why, "best step (%s) is cooler but does not lower the temperature penalty (%.2f -> %.2f)", st->text, st->pen_now, st->pen_step); return; }
  if (quieter && st->cost_step - st->pen_step > st->cost_now - st->pen_now - 0.01) { snprintf(st->why, sizeof st->why, "best step (%s) is quieter but does not lower the noise", st->text); return; }
  st->ok = 1;
}
