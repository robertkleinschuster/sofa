// sofa-fand learn | init | migrate
//
//   learn [-n] [-c CONF] [-d DATADIR] [-o REPORT] [--no-ident]
//       nightly (root, LaunchDaemon de.sofa.fanlearn 01:30): judge the step on trial (keep / roll
//       back), else fit the model, search and apply the next step; then one identification block.
//       -n: report only (stdout), nothing applied, no identification - any user.
//   init [-o FILE]   an Apple-equivalent reference for this Mac (stdout), checked by the parser
//   migrate [LOGDIR] the old collector's data (LOGDIR/sofa-fanlearn/*.csv, LOGDIR/fan-ident-*/phases.csv)
//                    into DATA_DIR (root, once)
#include "learn.h"
#include <dirent.h>
#include <errno.h>
#include <glob.h>
#include <math.h>
#include <pwd.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define DAY 86400.0

static int append_file(const char *src, FILE *o) {
  FILE *in = fopen(src, "r"); if (!in) return -1;
  static char b[65536]; int ok = 0;
  for (;;) {
    size_t r = fread(b, 1, sizeof b, in);
    if (r && fwrite(b, 1, r, o) != r) ok = -1;
    if (r < sizeof b) break;
  }
  if (ferror(in)) ok = -1;
  fclose(in);
  return ok;
}

// to := [prepend_from] + from, atomically (tmp + rename)
static int copy_atomic(const char *from, const char *to, const char *prepend_from) {
  char tmp[300]; snprintf(tmp, sizeof tmp, "%s.tmp", to);
  FILE *o = fopen(tmp, "w"); if (!o) return -1;
  int ok = 0;
  if (prepend_from && append_file(prepend_from, o)) ok = -1;
  if (append_file(from, o)) ok = -1;
  if (fflush(o) || fsync(fileno(o))) ok = -1;
  if (fclose(o)) ok = -1;
  if (ok || chmod(tmp, 0644) || rename(tmp, to)) { unlink(tmp); return -1; }
  return 0;
}

static int is_init_ref(const char *conf) {
  FILE *f = fopen(conf, "r"); if (!f) return 0;
  char line[256] = ""; char *ok = fgets(line, sizeof line, f); fclose(f);
  return ok && !strncmp(line, INIT_MARK, strlen(INIT_MARK)) && !strstr(line, "bootstrap");
}

static void report_model(FILE *rep, const model_t *m, const cfg_t *c) {
  fprintf(rep, "\n## Model\n\nFree-run error (C, held-out 2 h chunks) per mode; fan effect = share of the heat flow out that a fan at full speed carries.\n\n| sensor | minutes | ruhe | idle | playback | test | all: RMSE / 90 %% | gate | fan effect |\n|---|---|---|---|---|---|---|---|---|\n");
  for (int s = 0; s < c->nsens; s++) {
    const smodel_t *sm = &m->s[s];
    if (sm->fixed) { fprintf(rep, "| %s | - | ambient (reference) |||||||\n", c->sens[s].key); continue; }
    fprintf(rep, "| %s | %d |", c->sens[s].key, sm->npts);
    for (int md = 0; md < MODE_N; md++) { if (isnan(sm->rmse[md]) || sm->vmin[md] < 1) fprintf(rep, " - |"); else fprintf(rep, " %.2f (%.0f) |", sm->rmse[md], sm->vmin[md]); }
    if (sm->ok) fprintf(rep, " %.2f / %.1f | %.1f |", sm->rmse_all, sm->err90, gate_rmse(c, s));
    else fprintf(rep, " no model | %.1f |", gate_rmse(c, s));
    if (sm->ok) {
      char buf[160]; size_t o = 0; double k = sm->th[4];
      for (int n = 0; n < m->nfans; n++) if (c->fan[n].used) k += sm->th[5 + n] * c->fan[n].max / 1000;
      for (int n = 0; n < m->nfans; n++) if (c->fan[n].used && k > 0) {
        int w = snprintf(buf + o, sizeof buf - o, "%s%s %.0f %%", o ? ", " : "", c->fan[n].name, 100 * sm->th[5 + n] * c->fan[n].max / 1000 / k);
        if (w > 0 && (size_t)w < sizeof buf - o) o += (size_t)w;
      }
      fprintf(rep, " %s |\n", o ? buf : "-");
    } else fprintf(rep, " |\n");
  }
  for (int s = 0; s < c->nsens; s++) if (m->s[s].ok && !m->s[s].fixed && m->s[s].err90 > 0) { fprintf(rep, "\nLargest free-run error:"); break; }
  for (int s = 0; s < c->nsens; s++) if (m->s[s].ok && !m->s[s].fixed) fprintf(rep, " %s %.1f", c->sens[s].key, m->s[s].errmax);
  fprintf(rep, "\n");
}

static int rollback_trial(const trial_t *t, const char *conf) {
  if (!strcmp(t->kind, "reference")) {
    char prev[300]; snprintf(prev, sizeof prev, "%s/reference.prev", STATE_DIR);
    if (copy_atomic(prev, conf, NULL)) return -1;
    return reload_daemon();
  }
  return learned_rollback();
}

int learn_main(int argc, char **argv) {
  const char *conf = CONF_PATH, *dir = DATA_DIR, *out = NULL; int dry_run = 0, ident = 1;
  for (int i = 2; i < argc; i++) {
    if (!strcmp(argv[i], "-n")) dry_run = 1;
    else if (!strcmp(argv[i], "--no-ident")) ident = 0;
    else if (i + 1 < argc && !strcmp(argv[i], "-c")) conf = argv[++i];
    else if (i + 1 < argc && !strcmp(argv[i], "-d")) dir = argv[++i];
    else if (i + 1 < argc && !strcmp(argv[i], "-o")) out = argv[++i];
    else { fprintf(stderr, "usage: sofa-fand learn [-n] [-c CONF] [-d DATADIR] [-o REPORT] [--no-ident]\n"); return 2; }
  }
  if (!dry_run && geteuid()) { fprintf(stderr, "learn: root only (-n: report only)\n"); return 1; }
  if (load_machine_quiet()) { fprintf(stderr, "learn: machine: %s\n", machine.err); return 1; }
  static cfg_t ref, cur;
  if (cfg_load(&ref, conf, NULL, &machine)) { fprintf(stderr, "learn: reference: %s\n", ref.err); return 1; }
  cfg_load(&cur, conf, access(LEARNED_PATH, R_OK) == 0 ? LEARNED_PATH : NULL, &machine);
  char rtmp[300]; snprintf(rtmp, sizeof rtmp, "%s.tmp", out ? out : REPORT_PATH);
  FILE *rep = out ? fopen(rtmp, "w") : dry_run ? stdout : fopen(rtmp, "w");
  if (!rep) { fprintf(stderr, "learn: report %s: %s\n", rtmp, strerror(errno)); return 1; }
  time_t now = time(NULL); char ts[40]; strftime(ts, sizeof ts, "%Y-%m-%d %H:%M", localtime(&now));
  fprintf(rep, "# sofa-fand learner - %s%s\n\nMachine %s, reference %s%s, learned layer: ", ts, dry_run ? " (dry run)" : "", machine.model, conf, is_init_ref(conf) ? " (made by init)" : "");
  if (cur.learned > 0) fprintf(rep, "%u lines.\n", cur.learned_lines);
  else if (cur.learned < 0) fprintf(rep, "REFUSED (%s) - the reference applies alone.\n", cur.err_learned);
  else fprintf(rep, "none.\n");

  if (!dry_run && !strcmp(dir, DATA_DIR)) {   // the recorder's rows of the last hour too
    char ans[64]; if (ctl_request("FLUSH", ans, sizeof ans) == 0) sleep(25);
  }
  static series_t d;
  if (data_load(&d, &cur, &machine, dir, (double)now - LEARN_DAYS * DAY)) fprintf(rep, "\nData directory %s not readable.\n", dir);
  double mins[MODE_N] = { 0 };
  for (int i = 0; i < d.n; i++) { int md = bin_mode(&d.b[i]); if (md >= 0) mins[md]++; }
  fprintf(rep, "\nData (last %d days): %d minutes; ruhe %.0f, idle %.0f, playback %.0f, test %.0f.\n", LEARN_DAYS, d.n, mins[MD_RUHE], mins[MD_IDLE], mins[MD_PLAY], mins[MD_TEST]);
  static model_t m; model_fit(&m, &d, &cur, &machine);
  report_model(rep, &m, &cur);

  int waiting = 0; trial_t t; trial_load(&t);
  if (t.active) {
    char why[300]; int r = trial_judge(&t, &d, &cur, why, sizeof why, rep);
    fprintf(rep, "\nVerdict: %s\n", why);
    if (r < 0 && !dry_run) {
      int rb = rollback_trial(&t, conf);
      rejected_add(t.keys);
      history("rolled back (%s): %s - %s%s", t.kind, t.what, why, rb ? " - ROLLBACK FAILED" : "");
      t.active = 0; trial_save(&t);
      cfg_load(&cur, conf, access(LEARNED_PATH, R_OK) == 0 ? LEARNED_PATH : NULL, &machine);
      waiting = 1;                                             // the next step tomorrow, on the restored state
    } else if (r > 0 && !dry_run) { history("kept (%s): %s - %s", t.kind, t.what, why); t.active = 0; trial_save(&t); }
    else if (r == 0 || dry_run) waiting = r == 0;
  }

  if (!waiting && is_init_ref(conf) && cur.learned <= 0) {
    char why[200];
    if (model_trusted(&m, &ref, why, sizeof why)) {
      char next[300], prev[300]; snprintf(next, sizeof next, "%s/reference.next", STATE_DIR); snprintf(prev, sizeof prev, "%s/reference.prev", STATE_DIR);
      FILE *f = fopen(dry_run ? "/dev/stdout" : next, "w");
      static cfg_t prop;
      if (f) { bootstrap_reference(f, &ref, &m, &machine); fclose(f); }
      if (!dry_run && f && cfg_load(&prop, next, NULL, &machine) == 0) {
        if (copy_atomic(conf, prev, NULL) == 0 && copy_atomic(next, conf, NULL) == 0 && reload_daemon() == 0) {
          memset(&t, 0, sizeof t); t.active = 1; t.applied = (double)now;
          snprintf(t.kind, sizeof t.kind, "reference"); snprintf(t.keys, sizeof t.keys, "ref/bootstrap/+");
          snprintf(t.what, sizeof t.what, "quiet reference from the learned coupling (bootstrap)");
          trial_save(&t); history("applied (reference): bootstrap");
          fprintf(rep, "\n## Bootstrap\n\nThe init reference was replaced by quiet curves from the model (kept in %s); on trial.\n", prev);
        } else fprintf(rep, "\n## Bootstrap\n\nInstalling the quiet reference failed (%s).\n", strerror(errno));
      } else if (!dry_run) fprintf(rep, "\n## Bootstrap\n\nThe proposal did not parse: %s\n", prop.err);
      waiting = 1;
    } else fprintf(rep, "\n## Bootstrap\n\nNot yet: %s.\n", why);
  }

  if (!waiting) {
    scen_t sc[MAX_SCEN]; int nsc = scenarios(sc, &d, &cur);
    static step_t st; search_step(&st, &cur, &ref, &m, sc, nsc, rep);
    fprintf(rep, "\n## Step\n\n");
    if (!st.ok) fprintf(rep, "None: %s.\n", st.why);
    else {
      fprintf(rep, "%s (%s): cost %.2f -> %.2f.\n", st.text, st.kind, st.cost_now, st.cost_step);
      if (!dry_run) {
        char next[300]; snprintf(next, sizeof next, "%s/learned.next", STATE_DIR);
        FILE *f = fopen(next, "w");
        if (f) {
          fprintf(f, "# learned layer, written by sofa-fand learn %s\n", ts);
          learned_write(f, &st.eff, &ref);
          fclose(f);
          fflush(stdout);
          if (learned_install(next, conf) == 0) {
            memset(&t, 0, sizeof t); t.active = 1; t.applied = (double)now;
            snprintf(t.kind, sizeof t.kind, "%s", st.kind); snprintf(t.keys, sizeof t.keys, "%s", st.keys); snprintf(t.what, sizeof t.what, "%s", st.text);
            trial_save(&t);
            history("applied (%s): %s (simulated cost %.2f -> %.2f)", st.kind, st.text, st.cost_now, st.cost_step);
            fprintf(rep, "Applied; on trial.\n");
          } else { fprintf(rep, "Installing it FAILED (see the job's log).\n"); history("install failed: %s", st.text); }
        }
      }
    }
  } else fprintf(rep, "\n## Step\n\nNone tonight: a change is on trial or was just judged.\n");

  if (ident) ident_night(&cur, &machine, rep, dry_run);   // dry: the plan only
  data_free(&d);
  if (rep != stdout) {
    if (fclose(rep)) return 1;
    if (rename(rtmp, out ? out : REPORT_PATH)) { fprintf(stderr, "learn: %s\n", strerror(errno)); return 1; }
  }
  return 0;
}

int init_main(int argc, char **argv) {
  const char *out = argc >= 4 && !strcmp(argv[2], "-o") ? argv[3] : NULL;
  if (load_machine_quiet()) { fprintf(stderr, "init: machine: %s\n", machine.err); return 1; }
  char tmp[300];
  if (out) snprintf(tmp, sizeof tmp, "%s", out);
  else {
    snprintf(tmp, sizeof tmp, "/tmp/sofa-fand-init.XXXXXX");
    int fd = mkstemp(tmp); if (fd < 0) { fprintf(stderr, "init: %s\n", strerror(errno)); return 1; }
    close(fd);
  }
  FILE *f = fopen(tmp, "w");
  if (!f) { fprintf(stderr, "init: %s: %s\n", tmp, strerror(errno)); return 1; }
  init_reference(f, &machine);
  if (fclose(f)) return 1;
  static cfg_t c;
  int bad = cfg_load(&c, tmp, NULL, &machine);
  if (!out) { append_file(tmp, stdout); unlink(tmp); }
  if (bad) { fprintf(stderr, "init: the generated reference does not parse: %s\n", c.err); return 1; }
  fprintf(stderr, "init: %d sensors, %d fans - parses\n", c.nsens, machine.nfans);
  return 0;
}

static int cmpstr(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

int migrate_main(int argc, char **argv) {
  if (geteuid()) { fprintf(stderr, "migrate: root only\n"); return 1; }
  char logdir[300];
  if (argc >= 3) snprintf(logdir, sizeof logdir, "%s", argv[2]);
  else { struct passwd *pw = getpwuid(501); if (!pw) return 1; snprintf(logdir, sizeof logdir, "%s/Library/Logs", pw->pw_dir); }
  char mark[300]; snprintf(mark, sizeof mark, "%s/.migrated", DATA_DIR);
  if (access(mark, F_OK) == 0) { fprintf(stderr, "migrate: already done (%s)\n", mark); return 1; }
  mkdir(LEARNED_DIR, 0755); mkdir(DATA_DIR, 0755);
  char src[300]; snprintf(src, sizeof src, "%s/sofa-fanlearn", logdir);
  DIR *dp = opendir(src); if (!dp) { fprintf(stderr, "migrate: %s: %s\n", src, strerror(errno)); return 1; }
  char *names[1024]; int nn = 0; struct dirent *e;
  while ((e = readdir(dp)) && nn < 1024) { int y, mo, da; char tail[8]; if (sscanf(e->d_name, "%4d-%2d-%2d.%7s", &y, &mo, &da, tail) == 4 && !strcmp(tail, "csv")) names[nn++] = strdup(e->d_name); }
  closedir(dp);
  qsort(names, (size_t)nn, sizeof *names, cmpstr);
  int bad = 0;
  for (int i = 0; i < nn; i++) {
    char from[400], to[400]; snprintf(from, sizeof from, "%s/%s", src, names[i]); snprintf(to, sizeof to, "%s/%s", DATA_DIR, names[i]);
    int exists = access(to, F_OK) == 0;
    // the recorder may already have written this day: the old rows go first
    if (exists ? copy_atomic(to, to, from) : copy_atomic(from, to, NULL)) { fprintf(stderr, "migrate: %s: %s\n", names[i], strerror(errno)); bad = 1; }
    else printf("data %s%s\n", names[i], exists ? " (before the recorder's rows)" : "");
    free(names[i]);
  }
  char pat[400]; snprintf(pat, sizeof pat, "%s/fan-ident-*/phases.csv", logdir);
  glob_t g; int nt = 0;
  if (glob(pat, 0, NULL, &g) == 0) {
    char tests[300]; snprintf(tests, sizeof tests, "%s/tests.csv", DATA_DIR);
    FILE *o = fopen(tests, "a");
    for (size_t i = 0; o && i < g.gl_pathc; i++) {
      FILE *in = fopen(g.gl_pathv[i], "r"); if (!in) continue;
      char line[300];
      while (fgets(line, sizeof line, in)) {
        long a, b; char blk[32], step[32];
        if (sscanf(line, "%ld,%ld,%31[^,],%31[^,]", &a, &b, blk, step) == 4 && b > a) { fprintf(o, "%ld,%ld,%s-%s\n", a, b, blk, step); nt++; }
      }
      fclose(in);
    }
    if (o) fclose(o);
    globfree(&g);
  }
  printf("tests: %d identification intervals\n", nt);
  if (!bad) { FILE *f = fopen(mark, "w"); if (f) { fprintf(f, "%s\n", logdir); fclose(f); } }
  return bad;
}
