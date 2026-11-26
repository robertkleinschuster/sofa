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
// The same descent then runs without the box (still at most MAX_CHANGES parameters): where the
// search is heading. A fan curve acts only once its start crosses the temperature the sensor
// reaches, so a better point can lie further than one night's box with nothing gained on the way
// (a dead zone: e.g. a curve that must move 3.5 C before its fan starts at all). If tonight's box
// holds no step but that target passes every check of a step, the step is the first leg of the
// way there: every parameter moves toward the target by at most tonight's box, cooler moves first
// (quieter ones were chosen with the cooler ones in place and wait until those have arrived). Every
// leg must pass the same safety checks as a step; tonight's leg must lie in its own direction (a
// cooler leg must not raise the temperature penalty, a quieter or mixed one must lower the noise),
// since the trial judges it alone. Nothing is stored: each night plans again from fresh data, so
// the next leg is usually an ordinary step inside the box.
#include "learn.h"
#include <math.h>
#include <string.h>

typedef struct { int fan, k, prof; double lo, hi; char key[24]; } par_t;   // prof >= 0: profile base, else curve shift
#define MAX_PAR (MAX_FANS * MAX_CURVES + P_COUNT)
#define MAX_CHANGES 3      // parameters one step may move (a rolled-back step blocks each of them)
#define BOX_CURVE   2.0    // tonight's box: how far a curve shift may move in one step (C)
#define BOX_PROF    1.0    // ... a profile base shift
#define MAX_NIGHTS  16     // a longer way is not planned (= 2 x MAX_SHIFT / BOX_PROF, the longest there is)

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

static double box_of(const par_t *p) { return p->prof >= 0 ? BOX_PROF : BOX_CURVE; }
static int same(const cfg_t *a, const cfg_t *b, const par_t *ps, int np) {
  for (int i = 0; i < np; i++) if (fabs(get(a, &ps[i]) - get(b, &ps[i])) > 1e-9) return 0;
  return 1;
}

// the next leg from `from` toward `to`: each parameter by at most its box; quieter moves (relative
// to the current configuration) wait while a cooler one still needs more than this leg
static void leg(cfg_t *out, const cfg_t *from, const cfg_t *to, const cfg_t *cur, const par_t *ps, int np) {
  int cooler_left = 0;
  for (int i = 0; i < np; i++) { double a = get(from, &ps[i]), b = get(to, &ps[i]); if (b < get(cur, &ps[i]) - 1e-9 && fabs(b - a) > box_of(&ps[i]) + 1e-9) cooler_left = 1; }
  *out = *from;
  for (int i = 0; i < np; i++) {
    double a = get(from, &ps[i]), b = get(to, &ps[i]), bx = box_of(&ps[i]);
    if (fabs(b - a) < 1e-9 || (cooler_left && b > get(cur, &ps[i]))) continue;
    set(out, &ps[i], a + fmax(-bx, fmin(bx, b - a)));
  }
}

// a change from cur to c in words (text, keys, kind); returns its direction: bit 1 quieter, bit 2 cooler
static int describe(step_t *st, const cfg_t *cur, const cfg_t *c, const par_t *ps, int np) {
  size_t o = 0, ko = 0; int quieter = 0, cooler = 0;
  st->text[0] = st->keys[0] = 0;
  for (int i = 0; i < np; i++) {
    double a = get(cur, &ps[i]), b = get(c, &ps[i]);
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
  return quieter | cooler << 1;
}

// would the change from (z0, p0) to (z1, p1) be a step? NULL if so, else why not
static const char *refuse(int dir, double z0, double p0, double z1, double p1) {
  if (z0 - z1 < fmax(0.02 * z0, 0.05)) return "gain";
  // the gain must come from the part the step is about - else it is a simulation artefact
  // (hysteresis paths), not a reason to change the fans
  if (dir == 2 && p1 > p0 - 0.01) return "cooler but does not lower the temperature penalty";
  if ((dir & 1) && z1 - p1 > z0 - p0 - 0.01) return "quieter but does not lower the noise";
  return NULL;
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
  descend(&x, &c, &z, ps, np, BOX_CURVE, BOX_PROF, cur, quiet_ok, MAX_CHANGES);
  st->eff = c; st->cost_step = cost(&c, m, sc, nsc, NULL, &st->pen_step);
  int dir = describe(st, cur, &c, ps, np);
  const char *no = dir ? refuse(dir, st->cost_now, st->pen_now, st->cost_step, st->pen_step) : "none";
  // where it is heading: the same descent from the current configuration without the box
  cfg_t far = *cur; double zf = st->cost_now, pf;
  descend(&x, &far, &zf, ps, np, 2 * MAX_SHIFT, 2 * MAX_SHIFT, cur, quiet_ok, MAX_CHANGES);
  st->cost_best = cost(&far, m, sc, nsc, NULL, &pf);
  step_t fs; int fdir = describe(&fs, cur, &far, ps, np);
  const char *fno = fdir ? refuse(fdir, st->cost_now, st->pen_now, st->cost_best, pf) : "none";
  // the way there in legs of tonight's box, each checked like a step
  int nights = 0; const char *blocked = NULL; cfg_t first = *cur;
  for (cfg_t p = *cur; fdir && !same(&p, &far, ps, np); nights++) {
    if (nights == MAX_NIGHTS) { blocked = "too many nights"; break; }
    cfg_t q; leg(&q, &p, &far, cur, ps, np);
    if (!isfinite(eval(&x, &q))) { blocked = "a leg breaks a safety rule or pushes a sensor over its target"; break; }
    if (!nights) first = q;
    p = q;
  }
  if (rep) {
    if (dir) report_results(rep, "With the best step inside tonight's box", &c, m, sc, nsc);
    fprintf(rep, "\nWithout tonight's box (at most %d parameters) the search would go to cost %.2f:", MAX_CHANGES, st->cost_best);
    int any = 0;
    for (int i = 0; i < np; i++) { double a0 = get(cur, &ps[i]), b0 = get(&far, &ps[i]); if (fabs(a0 - b0) > 1e-9) { fprintf(rep, "%s %s %+.1f", any ? "," : "", ps[i].key, b0); any = 1; } }
    if (any) fprintf(rep, "; %d night%s away%s%s", nights, nights == 1 ? "" : "s", blocked ? ", way blocked: " : "", blocked ? blocked : "");
    fprintf(rep, "%s (%d simulations).\n", any ? "" : " nowhere else", x.evals);
  }
  if (!no) { st->ok = 1; return; }
  // no step inside the box: the first leg toward the target, if the target is a step itself
  if (!fno && !blocked && nights >= 1) {
    double zl, pl; zl = cost(&first, m, sc, nsc, NULL, &pl);
    step_t ls; int ldir = describe(&ls, cur, &first, ps, np);
    const char *lno = ldir == 2 ? (pl > st->pen_now + 0.01 ? "raises the temperature penalty" : NULL)
                                : (zl - pl > st->cost_now - st->pen_now - 0.01 ? "does not lower the noise" : NULL);
    if (rep) {
      report_results(rep, "With the first leg toward it", &first, m, sc, nsc);
      if (lno) fprintf(rep, "\nThat leg (%s) %s: not taken.\n", ls.text, lno);
    }
    if (!lno) {
      *st = (step_t){ .ok = 1, .eff = first, .cost_now = st->cost_now, .cost_step = zl, .cost_best = st->cost_best, .pen_now = st->pen_now, .pen_step = pl };
      snprintf(st->kind, sizeof st->kind, "%s", ls.kind); snprintf(st->keys, sizeof st->keys, "%s", ls.keys);
      snprintf(st->text, sizeof st->text, "%s - leg 1 of %d toward cost %.2f (%s)", ls.text, nights, st->cost_best, fs.text);
      return;
    }
  }
  if (!dir) { snprintf(st->why, sizeof st->why, "no step lowers the cost (%.2f)%s%s", st->cost_now, quiet_ok ? "" : "; quieter moves not allowed: ", quiet_ok ? "" : why); return; }
  if (!strcmp(no, "gain")) snprintf(st->why, sizeof st->why, "best step (%s) gains only %.3f of %.2f", st->text, st->cost_now - st->cost_step, st->cost_now);
  else snprintf(st->why, sizeof st->why, "best step (%s) is %s (%.2f/%.2f -> %.2f/%.2f)", st->text, no, st->cost_now - st->pen_now, st->pen_now, st->cost_step - st->pen_step, st->pen_step);
  st->eff = *cur;
}
