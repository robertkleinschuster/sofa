// The configuration: the reference (hand-made policy and curves, root) plus the learned layer.
//
// Reference (/usr/local/etc/sofa-fand.conf):
//   sensor KEY [trip T warn W] [ff cpu|gpu|both|none] [fast 1] [target T]
//       target: the steady-state temperature the learner keeps it below (default warn - 6)
//       trip/warn may be left out where the SMC tells Apple's limits: trip = Apple's warning (or
//       throttle - 2, shutdown - 5), warn = trip - 6. The key must exist on this Mac (or be HDD).
//   fan N [name X] [max R] minrun R hyst C up R/s down R/s minon S minoff S [profile_weight W] [ff_weight W] [loud W]
//       loud: how much this fan's noise counts for the learner (1 = normal; the iMac's HDD fan 4)
//       name and max default to the SMC's; a max above the SMC's is refused.
//   curve N KEY T:RPM ...        floor N KEY T RPM
//   profile NAME SHIFT [VOLSHIFT] [learn free|cooler] [noise W]
//       noise: how much quiet matters in this context for the learner (rest 3, playback 0.7: sound masks)
//       learn cooler: the learned layer may only make this profile cooler (in use, user 2026-11-19)
//   feedforward CPU GPU GPU_FULL, hdd_interval, hdd_stale, trip_hold, allow_uid, reply_dir
//
// Machine floors (added from the SMC, never from a file): when a sensor reaches Apple's own fan-start
// threshold (S<ab>F), every fan runs at least Apple's minimum - Apple's behaviour where it matters.
//
// Learned layer (/var/db/sofa-fand/learned.conf, installed only by `sofa-fand apply`):
//   shift N KEY DEG        read fan N's reference curve on KEY DEG C cooler (+ later/quieter, - earlier)
//   profile NAME BASE [VOL]
//   curve N KEY T:RPM ...  an additional curve (only ever adds demand)
// The layer is all or nothing: a line that is unknown, out of bounds or breaks a safety rule refuses
// the whole layer and the reference applies alone. Safety rules (independent of the learner):
//   - |shift| <= 8 C, |profile| <= 8 C; a "learn cooler" profile never gets quieter than the reference
//   - at a sensor's warn temperature, a reference curve never asks for less than the reference does
//     (the worst case over every profile and volume, feed-forward ignored)
//   - limits (trip, warn), floors, fan dynamics and the sensor set are not in the layer's reach
#include "fand.h"
#include <errno.h>
#include <math.h>
#include <pwd.h>
#include <stdlib.h>
#include <string.h>

cfg_t cfg;
const char *prof_name[P_COUNT] = { "default", "ruhe", "idle", "playback" };
int sens_index(const cfg_t *c, const char *key) {
  for (int i = 0; i < c->nsens; i++) if (!strcmp(c->sens[i].key, key)) return i;
  return -1;
}

double interp(const curve_t *c, double t) {
  if (t <= c->pts[0].t) return c->pts[0].rpm;
  for (int i = 1; i < c->npts; i++)
    if (t < c->pts[i].t) return c->pts[i-1].rpm + (c->pts[i].rpm - c->pts[i-1].rpm) * (t - c->pts[i-1].t) / (c->pts[i].t - c->pts[i-1].t);
  return c->pts[c->npts - 1].rpm;
}

double curve_demand(const cfg_t *c, int fan, int k, double temp) {
  const curve_t *cv = &c->fan[fan].curves[k];
  return interp(cv, temp - cv->shift);
}

static void cfg_defaults(cfg_t *c) {
  memset(c, 0, sizeof *c);
  c->hdd_interval = 30; c->hdd_stale = 150; c->trip_hold = 300; c->allow_uid = 501;
  c->gpu_full = 3000;
  c->prof[P_IDLE].learn = c->prof[P_PLAYBACK].learn = LEARN_COOLER;   // in use: never quieter than set
  for (int p = 0; p < P_COUNT; p++) c->prof[p].noise = 1;
  c->ok = 1;
}

static int parse_pt(const char *s, pt_t *p) {
  char *e; p->t = strtod(s, &e); if (*e != ':') return -1;
  p->rpm = strtod(e + 1, &e); if (*e) return -1;
  return (p->t >= 20 && p->t <= 110 && p->rpm >= 0 && p->rpm <= 7000) ? 0 : -1;
}

static int tokens(char *line, char **tok, int max) {
  char *h = strchr(line, '#'); if (h) *h = 0;
  int nt = 0;
  for (char *p = strtok(line, " \t\r\n"); p && nt < max; p = strtok(NULL, " \t\r\n")) tok[nt++] = p;
  return nt;
}

static int profile_index(const char *name) { for (int i = 0; i < P_COUNT; i++) if (!strcmp(name, prof_name[i])) return i; return -1; }

// curve N KEY T:R ... into fan N (shared by both layers)
static const char *parse_curve(cfg_t *c, char **tok, int nt, int learned) {
  int n = nt >= 2 ? atoi(tok[1]) : -1;
  if (nt < 4 || n < 0 || n >= MAX_FANS || !c->fan[n].used) return "curve before its fan line";
  fan_cfg_t *fc = &c->fan[n];
  int si = sens_index(c, tok[2]);
  if (si < 0 || fc->ncurves >= MAX_CURVES || nt - 3 > MAX_PTS) return "curve: unknown sensor or too many";
  curve_t *cv = &fc->curves[fc->ncurves]; memset(cv, 0, sizeof *cv); cv->sensor = si; cv->learned = learned;
  for (int i = 3; i < nt; i++) {
    if (parse_pt(tok[i], &cv->pts[cv->npts])) return "bad curve point";
    if (cv->npts && (cv->pts[cv->npts].t <= cv->pts[cv->npts-1].t || cv->pts[cv->npts].rpm < cv->pts[cv->npts-1].rpm)) return "curve points must rise";
    if (cv->pts[cv->npts].rpm > fc->max) return "curve point above fan max";
    cv->npts++;
  }
  fc->ncurves++;
  return NULL;
}

// trip/warn from Apple's limits when the reference leaves them out
static int apple_limits(const msens_t *ms, double *trip, double *warn) {
  if (!ms) return -1;
  double t = ms->warn ? ms->warn : ms->throttle ? ms->throttle - 2 : ms->shutdown ? ms->shutdown - 5 : 0;
  if (t < 30) return -1;
  *trip = t; *warn = t - 6;
  return 0;
}

#define BAD(...) do { snprintf(c->err, sizeof c->err, "%s:%d: " __VA_ARGS__); goto bad; } while (0)
static int load_reference(cfg_t *c, const char *path, const machine_t *m) {
  FILE *f = fopen(path, "r");
  if (!f) { snprintf(c->err, sizeof c->err, "%s: %s", path, strerror(errno)); return -1; }
  char line[1024]; int ln = 0;
  while (fgets(line, sizeof line, f)) {
    ln++;
    char *tok[40]; int nt = tokens(line, tok, 40);
    if (!nt) continue;
    if (!strcmp(tok[0], "sensor")) {
      if (nt < 2 || c->nsens >= MAX_SENS || !key_ok(tok[1]) || sens_index(c, tok[1]) >= 0) BAD("bad sensor line", path, ln);
      const msens_t *ms = m && m->ok ? machine_sensor(m, tok[1]) : NULL;
      if (m && m->ok && !ms && strcmp(tok[1], HDD_KEY)) BAD("sensor %s does not exist on this Mac (%s)", path, ln, tok[1], m->model);
      sens_cfg_t *s = &c->sens[c->nsens];
      snprintf(s->key, sizeof s->key, "%s", tok[1]);
      for (int i = 2; i + 1 < nt; i += 2) {
        if (!strcmp(tok[i], "trip")) s->trip = atof(tok[i + 1]);
        else if (!strcmp(tok[i], "warn")) s->warn = atof(tok[i + 1]);
        else if (!strcmp(tok[i], "fast")) s->fast = atoi(tok[i + 1]) != 0;
        else if (!strcmp(tok[i], "target")) s->target = atof(tok[i + 1]);
        else if (!strcmp(tok[i], "ff")) s->ff = !strcmp(tok[i+1], "cpu") ? FF_CPU : !strcmp(tok[i+1], "gpu") ? FF_GPU : !strcmp(tok[i+1], "both") ? FF_BOTH : FF_NONE;
        else BAD("unknown sensor option", path, ln);
      }
      if (nt % 2) BAD("sensor options come in pairs", path, ln);
      if (!s->trip && !s->warn && apple_limits(ms, &s->trip, &s->warn)) BAD("sensor %s: no trip/warn and no Apple limit to derive them from", path, ln, s->key);
      if (s->trip < 30 || s->trip > 110 || s->warn < 25 || s->warn >= s->trip) BAD("sensor needs warn < trip", path, ln);
      if (!s->target) s->target = s->warn - 6;
      if (s->target < 20 || s->target > s->warn) BAD("sensor target must lie below warn", path, ln);
      c->nsens++;
    } else if (!strcmp(tok[0], "fan")) {
      int n = nt >= 2 ? atoi(tok[1]) : -1;
      if (nt < 2 || n < 0 || n >= MAX_FANS || c->fan[n].used) BAD("bad fan line", path, ln);
      if (m && m->ok && n >= m->nfans) BAD("fan %d does not exist on this Mac (%d fans)", path, ln, n, m->nfans);
      fan_cfg_t *fc = &c->fan[n]; fc->used = 1; fc->pw = 1; fc->fw = 1; fc->loud = 1;
      if (m && m->ok) { fc->max = m->fan[n].max; snprintf(fc->name, sizeof fc->name, "%s", m->fan[n].name); }
      for (int i = 2; i + 1 < nt; i += 2) {
        const char *k = tok[i], *v = tok[i + 1];
        if (!strcmp(k, "name")) snprintf(fc->name, sizeof fc->name, "%s", v);
        else if (!strcmp(k, "max")) fc->max = atoi(v);
        else if (!strcmp(k, "minrun")) fc->minrun = atoi(v);
        else if (!strcmp(k, "hyst")) fc->hyst = atof(v);
        else if (!strcmp(k, "up")) fc->up = atof(v);
        else if (!strcmp(k, "down")) fc->down = atof(v);
        else if (!strcmp(k, "minon")) fc->minon = atoi(v);
        else if (!strcmp(k, "minoff")) fc->minoff = atoi(v);
        else if (!strcmp(k, "profile_weight")) fc->pw = atof(v);
        else if (!strcmp(k, "ff_weight")) fc->fw = atof(v);
        else if (!strcmp(k, "loud")) fc->loud = atof(v);
        else BAD("unknown fan option", path, ln);
      }
      if (nt % 2) BAD("fan options come in pairs", path, ln);
      if (m && m->ok && fc->max > m->fan[n].max) BAD("fan %d max %d above the SMC's %d", path, ln, n, fc->max, m->fan[n].max);
      if (!fc->name[0]) snprintf(fc->name, sizeof fc->name, "F%d", n);
      if (fc->max < 500 || fc->max > 7000 || fc->minrun < 0 || fc->minrun > fc->max || fc->hyst < 0 || fc->hyst > 10 ||
          fc->up <= 0 || fc->down <= 0 || fc->minon < 0 || fc->minoff < 0 || fc->pw < 0 || fc->pw > 1 || fc->fw < 0 || fc->fw > 1 || fc->loud <= 0 || fc->loud > 20) BAD("fan values out of range", path, ln);
    } else if (!strcmp(tok[0], "curve")) {
      const char *e = parse_curve(c, tok, nt, 0);
      if (e) BAD("%s", path, ln, e);
    } else if (!strcmp(tok[0], "floor")) {
      int n = nt >= 2 ? atoi(tok[1]) : -1;
      if (nt != 5 || n < 0 || n >= MAX_FANS || !c->fan[n].used) BAD("bad floor line", path, ln);
      fan_cfg_t *fc = &c->fan[n];
      int si = sens_index(c, tok[2]);
      if (si < 0 || fc->nfloors >= MAX_FLOORS) BAD("floor: unknown sensor or too many", path, ln);
      floor_t *fl = &fc->floors[fc->nfloors++];
      fl->sensor = si; fl->temp = atof(tok[3]); fl->rpm = atoi(tok[4]); fl->machine = 0;
      if (fl->temp < 20 || fl->temp > 110 || fl->rpm < 0 || fl->rpm > fc->max) BAD("floor out of range", path, ln);
    } else if (!strcmp(tok[0], "profile")) {
      // profile NAME SHIFT [VOLSHIFT] [learn free|cooler] [noise W]
      int p = nt >= 3 ? profile_index(tok[1]) : -1, i = 3;
      if (p < 0) BAD("bad profile line", path, ln);
      char *e; c->prof[p].base = strtod(tok[2], &e); if (*e) BAD("bad profile shift", path, ln);
      c->prof[p].vol = 0;
      if (nt > 3) { double v = strtod(tok[3], &e); if (!*e) { c->prof[p].vol = v; i = 4; } }
      for (; i + 1 < nt; i += 2) {
        if (!strcmp(tok[i], "learn")) c->prof[p].learn = !strcmp(tok[i + 1], "cooler") ? LEARN_COOLER : !strcmp(tok[i + 1], "free") ? LEARN_FREE : -1;
        else if (!strcmp(tok[i], "noise")) c->prof[p].noise = atof(tok[i + 1]);
        else BAD("unknown profile option", path, ln);
      }
      if (i != nt || c->prof[p].learn < 0) BAD("profile options: learn free|cooler, noise W", path, ln);
      if (fabs(c->prof[p].base) > MAX_SHIFT || fabs(c->prof[p].vol) > MAX_SHIFT) BAD("profile shift too large", path, ln);
      if (c->prof[p].noise <= 0 || c->prof[p].noise > 20) BAD("profile noise out of range", path, ln);
    } else if (!strcmp(tok[0], "feedforward") && nt == 4) {
      c->ff_cpu = atof(tok[1]); c->ff_gpu = atof(tok[2]); c->gpu_full = atof(tok[3]);
      if (c->ff_cpu < 0 || c->ff_cpu > 15 || c->ff_gpu < 0 || c->ff_gpu > 15 || c->gpu_full < 1) BAD("feedforward out of range", path, ln);
    } else if (!strcmp(tok[0], "hdd_interval") && nt == 2) c->hdd_interval = atoi(tok[1]);
    else if (!strcmp(tok[0], "hdd_stale") && nt == 2) c->hdd_stale = atoi(tok[1]);
    else if (!strcmp(tok[0], "trip_hold") && nt == 2) c->trip_hold = atoi(tok[1]);
    else if (!strcmp(tok[0], "allow_uid") && nt == 2) c->allow_uid = atoi(tok[1]);
    else if (!strcmp(tok[0], "reply_dir") && nt == 2 && tok[1][0] == '/' && strlen(tok[1]) < sizeof c->reply_dir - 1 && !strstr(tok[1], ".."))
      snprintf(c->reply_dir, sizeof c->reply_dir, "%s%s", tok[1], tok[1][strlen(tok[1]) - 1] == '/' ? "" : "/");
    else BAD("unknown line", path, ln);
    continue;
  bad:
    fclose(f); return -1;
  }
  fclose(f);
  if (c->hdd_interval < 5 || c->hdd_stale < 3 * c->hdd_interval || c->trip_hold < 30) { snprintf(c->err, sizeof c->err, "hdd_interval/hdd_stale/trip_hold invalid"); return -1; }
  int any = 0;
  for (int n = 0; n < MAX_FANS; n++) if (c->fan[n].used) { any = 1; if (!c->fan[n].ncurves) { snprintf(c->err, sizeof c->err, "fan %d has no curve", n); return -1; } }
  if (!c->nsens || !any) { snprintf(c->err, sizeof c->err, "no sensors or no fans"); return -1; }
  if (!c->reply_dir[0]) {   // Sofa's cache directory of the allowed user (portable: no fixed home)
    struct passwd *pw = getpwuid((uid_t)c->allow_uid);
    if (!pw || !pw->pw_dir || strlen(pw->pw_dir) > sizeof c->reply_dir - 32) { snprintf(c->err, sizeof c->err, "allow_uid %d has no home - set reply_dir", c->allow_uid); return -1; }
    snprintf(c->reply_dir, sizeof c->reply_dir, "%s/Library/Caches/Sofa/", pw->pw_dir);
  }
  return 0;
}

// Apple-minimum floors from the SMC: at Apple's own fan-start threshold every fan runs at least
// Apple's minimum. Added for every configured sensor the SMC names one for.
static int machine_floors(cfg_t *c, const machine_t *m) {
  if (!m || !m->ok) return 0;
  for (int i = 0; i < c->nsens; i++) {
    const msens_t *ms = machine_sensor(m, c->sens[i].key);
    if (!ms || !ms->fan_start) continue;
    for (int n = 0; n < MAX_FANS; n++) {
      fan_cfg_t *fc = &c->fan[n];
      if (!fc->used || n >= m->nfans || m->fan[n].min <= 0) continue;
      if (fc->nfloors >= MAX_FLOORS) { snprintf(c->err, sizeof c->err, "fan %d: too many floors with the SMC's", n); return -1; }
      floor_t *fl = &fc->floors[fc->nfloors++];
      fl->sensor = i; fl->temp = ms->fan_start; fl->rpm = m->fan[n].min < fc->max ? m->fan[n].min : fc->max; fl->machine = 1;
    }
  }
  return 0;
}

// lowest demand of curve k at its sensor's warn temperature over every profile and volume
static double warn_demand(const cfg_t *c, int n, int k) {
  const fan_cfg_t *f = &c->fan[n]; double w = c->sens[f->curves[k].sensor].warn, lo = 1e9;
  for (int p = 0; p < P_COUNT; p++)
    for (int v = 0; v <= 1; v++) {
      double d = curve_demand(c, n, k, w - f->pw * (c->prof[p].base + c->prof[p].vol * v));
      if (d < lo) lo = d;
    }
  return lo;
}

static int load_learned(cfg_t *c, const char *path, const cfg_t *ref) {
  FILE *f = fopen(path, "r");
  if (!f) { if (errno == ENOENT) return 0; snprintf(c->err_learned, sizeof c->err_learned, "%s: %s", path, strerror(errno)); return -1; }
  char line[1024]; int ln = 0; unsigned used = 0;
  #define LBAD(...) do { char _m[160]; snprintf(_m, sizeof _m, __VA_ARGS__); \
    snprintf(c->err_learned, sizeof c->err_learned, "learned:%d: %s", ln, _m); fclose(f); return -1; } while (0)
  while (fgets(line, sizeof line, f)) {
    ln++;
    char *tok[40]; int nt = tokens(line, tok, 40);
    if (!nt) continue;
    if (!strcmp(tok[0], "shift")) {
      int n = nt == 4 ? atoi(tok[1]) : -1, si = nt == 4 ? sens_index(c, tok[2]) : -1, hit = 0;
      char *e; double d = nt == 4 ? strtod(tok[3], &e) : NAN;
      if (n < 0 || n >= MAX_FANS || !c->fan[n].used || si < 0 || isnan(d) || *e) LBAD("bad shift line");
      for (int k = 0; k < c->fan[n].ncurves; k++) if (c->fan[n].curves[k].sensor == si && !c->fan[n].curves[k].learned) { c->fan[n].curves[k].shift = d; hit = 1; }
      if (!hit) LBAD("shift: fan %d has no reference curve on %s", n, tok[2]);
    } else if (!strcmp(tok[0], "profile")) {
      int p = nt >= 3 && nt <= 4 ? profile_index(tok[1]) : -1;
      if (p < 0) LBAD("bad profile line");
      double b = atof(tok[2]), v = nt == 4 ? atof(tok[3]) : ref->prof[p].vol;
      c->prof[p].base = b; c->prof[p].vol = v;
    } else if (!strcmp(tok[0], "curve")) {
      const char *e = parse_curve(c, tok, nt, 1);
      if (e) LBAD("%s", e);
    } else LBAD("unknown line '%s'", tok[0]);
    used++;
  }
  fclose(f);
  if (learned_check(c, ref, c->err_learned, sizeof c->err_learned)) return -1;
  c->learned_lines = used;
  return used ? 1 : 0;
  #undef LBAD
}

// Every rule the learned layer must keep, on the effective configuration against the reference -
// the daemon's check and the learner's feasibility test are this one function.
int learned_check(const cfg_t *c, const cfg_t *ref, char *err, size_t cap) {
  for (int n = 0; n < MAX_FANS; n++) {
    if (!c->fan[n].used) continue;
    for (int k = 0; k < c->fan[n].ncurves; k++)
      if (fabs(c->fan[n].curves[k].shift) > MAX_SHIFT + 1e-9) { snprintf(err, cap, "learned: shift %.1f on fan %d %s beyond %.0f C", c->fan[n].curves[k].shift, n, c->sens[c->fan[n].curves[k].sensor].key, MAX_SHIFT); return -1; }
  }
  for (int p = 0; p < P_COUNT; p++) {
    if (fabs(c->prof[p].base) > MAX_SHIFT + 1e-9 || fabs(c->prof[p].vol) > MAX_SHIFT + 1e-9) { snprintf(err, cap, "learned: profile %s beyond %.0f C", prof_name[p], MAX_SHIFT); return -1; }
    if (ref->prof[p].learn == LEARN_COOLER && (c->prof[p].base > ref->prof[p].base + 1e-9 || c->prof[p].vol > ref->prof[p].vol + 1e-9)) {
      snprintf(err, cap, "learned: profile %s may only get cooler than %.1f %.1f", prof_name[p], ref->prof[p].base, ref->prof[p].vol); return -1;
    }
  }
  for (int n = 0; n < MAX_FANS; n++) {
    if (!c->fan[n].used) continue;
    for (int k = 0; k < ref->fan[n].ncurves; k++) {
      double want = warn_demand(ref, n, k), got = warn_demand(c, n, k);
      if (got < want - 1) {
        snprintf(err, cap, "learned: fan %d curve %s asks %.0f rpm at warn, the reference %.0f", n, c->sens[c->fan[n].curves[k].sensor].key, got, want);
        return -1;
      }
    }
  }
  return 0;
}

void learned_write(FILE *o, const cfg_t *c, const cfg_t *ref) {
  for (int n = 0; n < MAX_FANS; n++) {
    if (!c->fan[n].used) continue;
    for (int k = 0; k < c->fan[n].ncurves; k++) {
      const curve_t *cv = &c->fan[n].curves[k];
      if (cv->learned) {
        fprintf(o, "curve %d %s", n, c->sens[cv->sensor].key);
        for (int i = 0; i < cv->npts; i++) fprintf(o, " %g:%g", cv->pts[i].t, cv->pts[i].rpm);
        fprintf(o, "\n");
      } else if (fabs(cv->shift) > 1e-9) fprintf(o, "shift %d %s %g\n", n, c->sens[cv->sensor].key, cv->shift);
    }
  }
  for (int p = 0; p < P_COUNT; p++)
    if (fabs(c->prof[p].base - ref->prof[p].base) > 1e-9 || fabs(c->prof[p].vol - ref->prof[p].vol) > 1e-9)
      fprintf(o, "profile %s %g %g\n", prof_name[p], c->prof[p].base, c->prof[p].vol);
}

int cfg_load(cfg_t *c, const char *ref, const char *learned, const machine_t *m) {
  cfg_defaults(c);
  if (load_reference(c, ref, m) || machine_floors(c, m)) { c->ok = 0; return -1; }
  if (!learned) return 0;
  static cfg_t r;                  // the reference alone (static: cfg_t is large for a guard stack)
  r = *c;
  int l = load_learned(c, learned, &r);
  if (l < 0) {
    char why[sizeof c->err_learned]; memcpy(why, c->err_learned, sizeof why);
    *c = r; c->learned = -1; memcpy(c->err_learned, why, sizeof why);   // the reference applies alone
    return 0;
  }
  c->learned = l;
  return 0;
}

void cfg_print(FILE *o, const cfg_t *c) {
  static const char *ffn[] = { "none", "cpu", "gpu", "both" };
  for (int i = 0; i < c->nsens; i++) fprintf(o, "sensor %-4s trip %.1f warn %.1f target %.1f ff %s%s\n", c->sens[i].key, c->sens[i].trip, c->sens[i].warn, c->sens[i].target, ffn[c->sens[i].ff], c->sens[i].fast ? " fast 1" : "");
  for (int n = 0; n < MAX_FANS; n++) if (c->fan[n].used) {
    const fan_cfg_t *f = &c->fan[n];
    fprintf(o, "fan %d %s max %d minrun %d hyst %.1f up %.0f down %.0f minon %d minoff %d profile_weight %.2f ff_weight %.2f loud %.1f\n", n, f->name, f->max, f->minrun, f->hyst, f->up, f->down, f->minon, f->minoff, f->pw, f->fw, f->loud);
    for (int k = 0; k < f->ncurves; k++) {
      fprintf(o, "  curve %-4s", c->sens[f->curves[k].sensor].key);
      for (int i = 0; i < f->curves[k].npts; i++) fprintf(o, " %.1f:%.0f", f->curves[k].pts[i].t, f->curves[k].pts[i].rpm);
      if (f->curves[k].learned) fprintf(o, "   (learned)");
      else if (f->curves[k].shift) fprintf(o, "   (learned shift %+.1f)", f->curves[k].shift);
      fprintf(o, "\n");
    }
    for (int k = 0; k < f->nfloors; k++) fprintf(o, "  floor %-4s >= %.1f -> %d%s\n", c->sens[f->floors[k].sensor].key, f->floors[k].temp, f->floors[k].rpm, f->floors[k].machine ? "   (SMC fan start)" : "");
  }
  for (int p = 0; p < P_COUNT; p++) fprintf(o, "profile %s %.1f %.1f%s noise %.1f\n", prof_name[p], c->prof[p].base, c->prof[p].vol, c->prof[p].learn == LEARN_COOLER ? " learn cooler" : "", c->prof[p].noise);
  fprintf(o, "feedforward cpu %.1f gpu %.1f gpu_full %.0f\n", c->ff_cpu, c->ff_gpu, c->gpu_full);
  fprintf(o, "hdd_interval %d hdd_stale %d trip_hold %d allow_uid %d reply_dir %s\n", c->hdd_interval, c->hdd_stale, c->trip_hold, c->allow_uid, c->reply_dir);
  if (c->learned > 0) fprintf(o, "learned layer: %u lines in effect\n", c->learned_lines);
  else if (c->learned < 0) fprintf(o, "learned layer REFUSED: %s\n", c->err_learned);
  else fprintf(o, "learned layer: none\n");
}
