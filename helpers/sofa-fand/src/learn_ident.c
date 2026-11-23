// Identification: one block of fan steps per night while Sofa rests, run by the daemon itself
// (ctl IDENT: forced speeds with every safety rule of the controller - limits, floors, ramps, the
// step ends at once when Sofa leaves rest, a sensor nears warn or anything faults). The recorder
// tags those rows; the model learns each fan's effect from them. No artificial load (the old power
// supply), no display tricks: the machine as it rests.
//
// Block: base (the curves, tagged), then each fan alone at a moderate speed (1.6 x Apple's minimum,
// at most its max) with the others on their curves, then every fan at its lowest stable speed.
// 15 min each; the order of the fan steps rotates night by night.
#include "learn.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define STEP_S 900

typedef struct { char tag[24]; int rpm[MAX_FANS]; } istep_t;

static int plan(istep_t *st, const cfg_t *c, const machine_t *m, int rot) {
  int nf = 0, fans[MAX_FANS], ns = 0;
  for (int n = 0; n < MAX_FANS; n++) if (c->fan[n].used) fans[nf++] = n;
  istep_t s; memset(&s, 0, sizeof s);
  for (int n = 0; n < MAX_FANS; n++) s.rpm[n] = -1;
  snprintf(s.tag, sizeof s.tag, "id-base"); st[ns++] = s;
  for (int i = 0; i < nf; i++) {
    int n = fans[(i + rot) % nf];
    istep_t h = s; int amin = m && m->ok ? m->fan[n].min : 0;
    double r = amin > 0 ? 1.6 * amin : c->fan[n].max / 2.0;
    if (r > c->fan[n].max) r = c->fan[n].max;
    if (r < c->fan[n].minrun) r = c->fan[n].minrun;
    h.rpm[n] = (int)lround(r);
    snprintf(h.tag, sizeof h.tag, "id-%s-%d", c->fan[n].name, h.rpm[n]);
    st[ns++] = h;
  }
  istep_t lo = s;
  for (int i = 0; i < nf; i++) { int n = fans[i]; lo.rpm[n] = c->fan[n].minrun > 0 ? c->fan[n].minrun : 500; }
  snprintf(lo.tag, sizeof lo.tag, "id-low"); st[ns++] = lo;
  return ns;
}

static int ident_running(void) {
  static char st[8192];
  if (ctl_request("STATUS", st, sizeof st)) return -1;
  return strstr(st, "\nident ") != NULL;
}

int ident_night(const cfg_t *c, const machine_t *m, FILE *rep, int dry_run) {
  int rot = 0; FILE *f = fopen(IDENT_STATE, "r");
  if (f) { if (fscanf(f, "%d", &rot) != 1) rot = 0; fclose(f); }
  istep_t st[MAX_FANS + 2]; int ns = plan(st, c, m, rot);
  if (rep) { fprintf(rep, "\n## Identification\n\n"); for (int i = 0; i < ns; i++) fprintf(rep, "%s%s", i ? ", " : "Plan: ", st[i].tag); fprintf(rep, " (%d s each)\n", STEP_S); }
  if (dry_run) return 0;
  if ((f = fopen(IDENT_STATE ".tmp", "w"))) { fprintf(f, "%d\n", rot + 1); fclose(f); rename(IDENT_STATE ".tmp", IDENT_STATE); }
  int done = 0;
  for (int i = 0; i < ns; i++) {
    char cmd[200], ans[512]; size_t o = (size_t)snprintf(cmd, sizeof cmd, "IDENT %d %s", STEP_S, st[i].tag);
    int last = 0; for (int n = 0; n < MAX_FANS; n++) if (c->fan[n].used) last = n + 1;
    for (int n = 0; n < last && o < sizeof cmd; n++) o += (size_t)snprintf(cmd + o, sizeof cmd - o, " %d", st[i].rpm[n]);
    if (ctl_request(cmd, ans, sizeof ans)) {
      char *nl = strchr(ans, '\n'); if (nl) *nl = 0;
      if (rep) fprintf(rep, "- %s: not started (%s)\n", st[i].tag, ans[0] ? ans : "daemon not reachable");
      history("ident %s not started: %s", st[i].tag, ans[0] ? ans : "daemon not reachable");
      break;
    }
    time_t t0 = time(NULL); int early = 0;
    for (;;) {
      sleep(15);
      int r = ident_running(); double el = difftime(time(NULL), t0);
      if (r == 0) { early = el < STEP_S - 30; break; }
      if (r < 0 || el > STEP_S + 120) { ctl_request("IDENTSTOP", ans, sizeof ans); early = 1; break; }
    }
    double el = difftime(time(NULL), t0);
    if (rep) fprintf(rep, "- %s: %.0f s%s\n", st[i].tag, el, early ? " - ended early (Sofa left rest, a limit or a fault; see the daemon log)" : "");
    if (early) { history("ident %s ended early after %.0f s", st[i].tag, el); break; }
    done++;
  }
  history("ident: %d of %d steps", done, ns);
  return done;
}
