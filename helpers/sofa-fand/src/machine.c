// What this Mac has, read from the SMC - nothing here is configured or specific to one model.
//
// Fans:    FNum; per fan F<n>ID (name in bytes 4..15), F<n>Mn (Apple's minimum), F<n>Mx (maximum).
// Sensors: every key T??? of type sp78 that reads a plausible temperature (5..125 C).
// Apple's limits (naming as on every Intel Mac SMC seen so far, sp78 values):
//   S<ab>F / S<ab>W / S<ab>P / S<ab>S  fan start / warning / throttle / shutdown for T<ab>*
//                                       (iMac12,2: Sp2F 96 -> Tp2H, SL0F 58.4 -> TL0P, SS0F 50 -> TS0P)
//   S<a>Tg                              control target for T<a>* (SGTg 77 GPU, SCTg 70 CPU, SOTg 55 ODD)
//   SCXC                                PECI target -> TCXc;  SGTT -> throttle of TG* (inferred)
// A limit is only taken when it is plausible (30..130 C). What a Mac does not expose stays 0.
#include "fand.h"
#include <string.h>
#include <sys/sysctl.h>

machine_t machine;

static int fan_name(int n, char out[8]) {
  unsigned char b[32]; UInt32 sz, ty; char k[5]; snprintf(k, sizeof k, "F%dID", n);
  if (smc_read(k, b, &sz, &ty) || sz < 16) return -1;
  int o = 0;
  for (int i = 4; i < 16 && o < 7; i++) { if (b[i] == 0) break; if (b[i] > 0x20 && b[i] < 0x7f) out[o++] = (char)b[i]; else if (o) break; }
  out[o] = 0;
  return o ? 0 : -1;
}

static msens_t *find(machine_t *m, const char *key) {
  for (int i = 0; i < m->nsens; i++) if (!strcmp(m->sens[i].key, key)) return &m->sens[i];
  return NULL;
}

// apply a limit to every sensor whose key starts with prefix (T + 1 or 2 characters)
static void limit_for(machine_t *m, const char *prefix, char kind, double v) {
  if (v < 30 || v > 130) return;
  size_t pl = strlen(prefix);
  for (int i = 0; i < m->nsens; i++) {
    msens_t *s = &m->sens[i];
    if (strncmp(s->key, prefix, pl)) continue;
    double *slot = kind == 'F' ? &s->fan_start : kind == 'W' ? &s->warn : kind == 'P' ? &s->throttle : kind == 'S' ? &s->shutdown : &s->target;
    if (*slot == 0 || v < *slot) *slot = v;      // two limits for one sensor: the stricter
  }
}

int machine_discover(machine_t *m) {
  memset(m, 0, sizeof *m);
  size_t ml = sizeof m->model;
  if (sysctlbyname("hw.model", m->model, &ml, NULL, 0)) snprintf(m->model, sizeof m->model, "?");
  unsigned char b[32]; UInt32 sz, ty;
  if (smc_read("FNum", b, &sz, &ty) || sz != 1) { snprintf(m->err, sizeof m->err, "SMC: FNum unreadable"); return -1; }
  m->nfans = b[0] > MAX_FANS ? MAX_FANS : b[0];
  for (int n = 0; n < m->nfans; n++) {
    char k[5]; double v;
    if (fan_name(n, m->fan[n].name)) snprintf(m->fan[n].name, sizeof m->fan[n].name, "F%d", n);
    snprintf(k, sizeof k, "F%dMn", n); m->fan[n].min = smc_fpe2(k, &v) == 0 ? (int)v : 0;
    snprintf(k, sizeof k, "F%dMx", n); m->fan[n].max = smc_fpe2(k, &v) == 0 ? (int)v : 0;
    if (m->fan[n].max < 500 || m->fan[n].max > 7000 || m->fan[n].min < 0 || m->fan[n].min > m->fan[n].max) {
      snprintf(m->err, sizeof m->err, "SMC: fan %d limits implausible (min %d, max %d)", n, m->fan[n].min, m->fan[n].max); return -1;
    }
  }
  int nk = smc_key_count();
  if (nk <= 0 || nk > 4096) { snprintf(m->err, sizeof m->err, "SMC: key count unreadable"); return -1; }
  // temperatures first: the limits below are matched against them
  for (int i = 0; i < nk && m->nsens < (int)(sizeof m->sens / sizeof m->sens[0]); i++) {
    char k[5]; double v;
    if (smc_key_at(i, k) || k[0] != 'T' || !key_ok(k)) continue;
    if (smc_sp78(k, &v) || v < 5 || v > 125) continue;
    snprintf(m->sens[m->nsens++].key, 5, "%s", k);
  }
  for (int i = 0; i < nk; i++) {
    char k[5]; double v;
    if (smc_key_at(i, k) || k[0] != 'S' || smc_sp78(k, &v)) continue;
    char p[4] = { 'T', 0, 0, 0 };
    if (!strcmp(k, "SCXC")) continue;                          // below: it overrides SCTg for TCXc
    if (!strcmp(k, "SGTT")) { limit_for(m, "TG", 'P', v); continue; }
    if (k[2] == 'T' && k[3] == 'g') { p[1] = k[1]; limit_for(m, p, 'g', v); continue; }   // S<a>Tg
    if (k[3] && strchr("FWPS", k[3])) { p[1] = k[1]; p[2] = k[2]; limit_for(m, p, k[3], v); }
  }
  double peci; msens_t *tx = find(m, "TCXc");
  if (tx && smc_sp78("SCXC", &peci) == 0 && peci >= 30 && peci <= 130) tx->target = peci;
  // power (W): the first key of each list that reads plausibly - names differ between models
  static const char *tot[] = { "PDTR", "PSTR", "PPBR", "PDTC", NULL }, *cpu[] = { "PCPT", "PCPC", "PC0C", "PCTR", NULL }, *gpu[] = { "PG0R", "PCPG", "PC0G", "PGTR", NULL };
  const char **lists[3] = { tot, cpu, gpu }; char *dst[3] = { m->pw_total, m->pw_cpu, m->pw_gpu };
  for (int l = 0; l < 3; l++) for (int i = 0; lists[l][i]; i++) { double w; if (smc_num(lists[l][i], &w) == 0 && w >= 0 && w < 1000) { snprintf(dst[l], 5, "%s", lists[l][i]); break; } }
  for (int i = 0; i < m->nsens; i++) if (!strncmp(m->sens[i].key, "TA", 2)) { snprintf(m->ambient, sizeof m->ambient, "%s", m->sens[i].key); break; }
  m->ok = 1;
  return 0;
}

const msens_t *machine_sensor(const machine_t *m, const char *key) {
  for (int i = 0; i < m->nsens; i++) if (!strcmp(m->sens[i].key, key)) return &m->sens[i];
  return NULL;
}

void machine_print(FILE *o, const machine_t *m) {
  if (!m->ok) { fprintf(o, "machine: %s\n", m->err); return; }
  fprintf(o, "# %s: %d fans, %d temperature keys (Apple limits from the SMC; 0 = none)\n", m->model, m->nfans, m->nsens);
  fprintf(o, "power total %s cpu %s gpu %s, ambient %s\n", m->pw_total[0] ? m->pw_total : "-", m->pw_cpu[0] ? m->pw_cpu : "-", m->pw_gpu[0] ? m->pw_gpu : "-", m->ambient[0] ? m->ambient : "-");
  for (int n = 0; n < m->nfans; n++) fprintf(o, "fan %d %-4s min %d max %d\n", n, m->fan[n].name, m->fan[n].min, m->fan[n].max);
  for (int i = 0; i < m->nsens; i++) {
    const msens_t *s = &m->sens[i]; double t = 0;
    smc_temp(s->key, &t);
    fprintf(o, "temp %-4s %5.1f", s->key, t);
    if (s->fan_start) fprintf(o, "  fan_start %.1f", s->fan_start);
    if (s->warn) fprintf(o, "  warn %.1f", s->warn);
    if (s->throttle) fprintf(o, "  throttle %.1f", s->throttle);
    if (s->shutdown) fprintf(o, "  shutdown %.1f", s->shutdown);
    if (s->target) fprintf(o, "  target %.1f", s->target);
    fprintf(o, "\n");
  }
}
