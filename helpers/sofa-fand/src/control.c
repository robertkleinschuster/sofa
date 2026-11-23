// The control step: sensors -> curves (learned shifts applied), floors, hysteresis, ramps,
// on/off discipline -> F<n>Tg + FS!. Faults hand the fans to the SMC, temperature limits force every
// fan to its maximum. No file or socket I/O here: only SMC calls, the helper threads' last values
// and arithmetic.
#include "fand.h"
#include <math.h>
#include <string.h>
#include <unistd.h>

const char *mode_name[] = { "curve", "smc", "trip", "disabled" };
pub_t pub; pthread_mutex_t pub_mx = PTHREAD_MUTEX_INITIALIZER;
hint_t hint = { -1, -1, 0, 0, 0, -1e9 }; pthread_mutex_t hint_mx = PTHREAD_MUTEX_INITIALIZER;
pthread_mutex_t ctl_mx = PTHREAD_MUTEX_INITIALIZER;
volatile int sleeping;
volatile double woke_at = -1;
int wake_pipe[2] = { -1, -1 }, push_pipe[2] = { -1, -1 };
void poke(int fd) { if (fd >= 0) { char c = 1; ssize_t w = write(fd, &c, 1); (void)w; } }

static struct {
  int mode; char reason[96]; double trip_until;
  fanstate_t fs[MAX_FANS];         // commanded rpm (after ramps), on/off times - policy.c
  double stall_since[MAX_FANS];
  double force[MAX_FANS];          // identification: held speed per fan (-1: curves)
  double force_until; char force_tag[24];
  double temp[MAX_SENS]; int temp_ok[MAX_SENS];
  double ac[MAX_FANS];
  double cpu_ema, gpu_ema;
  int level; int fan_count;
  double dt, last_step, last_full; int full;   // adaptive sampling
  double fast_until;                            // context change or CPU load jump: sample fast
  double started; unsigned long locked_kb;
  unsigned cfg_gen;
} st;

double control_next_dt(void) { return st.dt > 0 ? st.dt : DT_FAST; }
int control_fan_count(void) { return st.fan_count; }
void control_after_wake(void) { st.dt = 0; st.last_step = 0; }
unsigned long control_locked_kb(void) { return st.locked_kb; }
void control_set_locked_kb(unsigned long kb) { st.locked_kb = kb; }
double control_started(void) { return st.started; }

static void set_mode(int m, const char *reason) {
  if (st.mode != m || strcmp(st.reason, reason)) logf_("-> %s (%s)", mode_name[m], reason);
  st.mode = m; snprintf(st.reason, sizeof st.reason, "%s", reason);
}

void control_init(double now) {
  st.started = now;
  st.fan_count = machine.ok ? machine.nfans : 0;
  for (int n = 0; n < MAX_FANS; n++) {
    st.fs[n].out = 0; char k[5]; snprintf(k, sizeof k, "F%dAc", n); double a;
    if (n < st.fan_count && smc_fpe2(k, &a) == 0) st.fs[n].out = a;   // take over smoothly from the current speed
    st.fs[n].on_since = st.started - 3600; st.fs[n].off_since = 0; st.force[n] = -1;
  }
  st.mode = M_SMC; snprintf(st.reason, sizeof st.reason, "start");
  sleeping = shm->sleeping;                                        // restarted between WillSleep and wake
  if (shm->trip_until > st.started) {                              // a trip outlives a controller restart
    st.mode = M_TRIP; st.trip_until = shm->trip_until;
    snprintf(st.reason, sizeof st.reason, shm->trip_max ? "limit (inherited), all fans max" : "fault (inherited)");
  }
  if (!machine.ok) { st.mode = M_DISABLED; snprintf(st.reason, sizeof st.reason, "machine: %.80s", machine.err); }
  else if (!cfg.ok) { st.mode = M_DISABLED; snprintf(st.reason, sizeof st.reason, "config: %.80s", cfg.err); }
}

// Fault: SMC regulates, controller rests for trip_hold.
static void ident_end(const char *why);
static void fault(const char *why, double now) {
  ident_end("fault");
  int failed = smc_auto();
  shm->forced = 0;
  char r[96]; snprintf(r, sizeof r, "%s%s", why, failed ? ", FS! RESET FAILED" : "");
  set_mode(M_TRIP, r);
  st.trip_until = now + cfg.trip_hold;
  shm->trip_max = 0; shm->trip_until = st.trip_until;
  for (int n = 0; n < MAX_FANS; n++) { st.fs[n].out = st.ac[n] > 0 ? st.ac[n] : 0; st.stall_since[n] = 0; }
}

// ---- identification steps (sofa-fand learn, at rest): hold fans at given speeds for a while.
// Every safeguard stays: floors, trips, faults. It ends early when the context leaves "ruhe", when a
// sensor comes within 3 C of its warn point, on a trip or fault, or when its time is up.
static void ident_end(const char *why) {
  if (!st.force_tag[0]) return;
  logf_("identification %s ended: %s", st.force_tag, why);
  for (int n = 0; n < MAX_FANS; n++) st.force[n] = -1;
  st.force_tag[0] = 0; st.force_until = 0;
}
int control_ident(const int *rpm, int nfans, double secs, const char *tag, char *err, size_t cap) {
  pthread_mutex_lock(&ctl_mx);
  int r = -1;
  pthread_mutex_lock(&hint_mx); int ruhe = hint.ctx == P_RUHE && now_s() < hint.until; pthread_mutex_unlock(&hint_mx);
  if (st.mode != M_CURVE) snprintf(err, cap, "not regulating (%s)", mode_name[st.mode]);
  else if (!ruhe && !dry) snprintf(err, cap, "Sofa does not rest");
  else if (secs < 10 || secs > 3600) snprintf(err, cap, "duration 10..3600 s");
  else {
    r = 0;
    for (int n = 0; n < MAX_FANS; n++) {
      int want = n < nfans ? rpm[n] : -1;
      if (want >= 0 && (n >= st.fan_count || !cfg.fan[n].used)) { snprintf(err, cap, "fan %d not controlled", n); r = -1; break; }
      if (want > (n < MAX_FANS ? cfg.fan[n].max : 0)) want = cfg.fan[n].max;
      st.force[n] = want;
    }
    if (r == 0) {
      st.force_until = now_s() + secs; snprintf(st.force_tag, sizeof st.force_tag, "%s", tag);
      st.dt = 0; poke(wake_pipe[1]);
      logf_("identification %s: %.0f s", tag, secs);
    } else for (int n = 0; n < MAX_FANS; n++) st.force[n] = -1;
  }
  pthread_mutex_unlock(&ctl_mx);
  return r;
}
void control_ident_stop(void) { pthread_mutex_lock(&ctl_mx); ident_end("stopped"); pthread_mutex_unlock(&ctl_mx); }

static int profile_now(double now, double *vol) {
  int p = P_DEFAULT; *vol = 0;
  pthread_mutex_lock(&hint_mx);
  if (hint.ctx >= 0 && now < hint.until) { p = hint.ctx; *vol = hint.vol >= 0 ? hint.vol : 0.5; }
  pthread_mutex_unlock(&hint_mx);
  return p;
}

static void publish(int profile, double shift) {
  pthread_mutex_lock(&pub_mx);
  if (pub.level != st.level) { pub.level_seq++; poke(push_pipe[1]); }
  pub.level = st.level; pub.mode = st.mode; pub.profile = profile; pub.shift = shift;
  pub.nsens = cfg.nsens;
  for (int i = 0; i < cfg.nsens; i++) {
    memcpy(pub.key[i], cfg.sens[i].key, 5); pub.warn[i] = cfg.sens[i].warn; pub.trip[i] = cfg.sens[i].trip; pub.ff[i] = cfg.sens[i].ff;
    pub.temp[i] = st.temp[i]; pub.temp_ok[i] = st.temp_ok[i];
  }
  for (int n = 0; n < MAX_FANS; n++) {
    pub.fan_used[n] = cfg.fan[n].used && n < st.fan_count; memcpy(pub.fan_name[n], cfg.fan[n].name, 8);
    pub.ac[n] = st.ac[n]; pub.target[n] = st.fs[n].out;
  }
  pub.cpu = st.cpu_ema; pub.gpu = st.gpu_ema;
  snprintf(pub.reason, sizeof pub.reason, "%s", st.reason);
  pub.learned = cfg.learned; pub.learned_lines = cfg.learned_lines; snprintf(pub.err_learned, sizeof pub.err_learned, "%s", cfg.err_learned);
  pub.cfg_gen = st.cfg_gen;
  snprintf(pub.ident, sizeof pub.ident, "%s", st.force_tag); pub.ident_left = st.force_tag[0] ? st.force_until - now_s() : 0;
  memcpy(pub.reply_dir, cfg.reply_dir, sizeof pub.reply_dir); pub.allow_uid = cfg.allow_uid;
  pthread_mutex_unlock(&pub_mx);
}

static void read_sensors(double now) {
  for (int i = 0; i < cfg.nsens; i++) {
    int hdd = !strcmp(cfg.sens[i].key, HDD_KEY);
    if (!st.full && !cfg.sens[i].fast && !hdd) continue;   // keep the last value
    double t = NAN; int ok;
    if (hdd) ok = hdd_reading(now, cfg.hdd_stale, &t);
    else ok = smc_temp(cfg.sens[i].key, &t) == 0;
    st.temp_ok[i] = ok && !isnan(t);
    st.temp[i] = st.temp_ok[i] ? t : NAN;
  }
  for (int n = 0; n < st.fan_count; n++) {
    if (!st.full && st.fs[n].out <= 0) continue;             // a stopped fan needs no stall check
    char k[5]; snprintf(k, sizeof k, "F%dAc", n); if (smc_fpe2(k, &st.ac[n])) st.ac[n] = NAN;
  }
}

// level for Sofa: 0 normal, 1 warm (warn-5), 2 hot (warn), 3 critical (trip-2 or a trip); 2 C hysteresis down
static void update_level(void) {
  int lv = 0;
  for (int i = 0; i < cfg.nsens; i++) {
    if (!st.temp_ok[i]) continue;
    double t = st.temp[i], w = cfg.sens[i].warn, tr = cfg.sens[i].trip;
    int need = t >= tr - 2 ? 3 : t >= w ? 2 : t >= w - 5 ? 1 : 0;
    int keep = t >= tr - 4 ? 3 : t >= w - 2 ? 2 : t >= w - 7 ? 1 : 0;   // what holds the current level
    int l = need > st.level ? need : (keep >= st.level ? st.level : need);
    if (l > lv) lv = l;
  }
  if (st.mode == M_TRIP) lv = 3;
  st.level = lv;
}

// Reload: the guard read a new configuration. The fans keep their speeds; the next step reads
// every sensor (the sensor list may have changed) and writes everything again.
void control_take_cfg(const cfg_t *n) {
  pthread_mutex_lock(&ctl_mx);
  cfg = *n;
  st.cfg_gen++;
  for (int i = 0; i < MAX_SENS; i++) { st.temp_ok[i] = 0; st.temp[i] = NAN; }
  st.dt = 0; smc_forget_writes();
  if (st.mode == M_DISABLED && cfg.ok && machine.ok) { st.mode = M_SMC; snprintf(st.reason, sizeof st.reason, "reloaded"); }
  if (!cfg.ok) { smc_auto(); shm->forced = 0; set_mode(M_DISABLED, "config refused on reload"); }
  pthread_mutex_unlock(&ctl_mx);
  if (cfg.learned < 0) logf_("reload: learned layer refused (%s) - reference only", cfg.err_learned);
  else logf_("reload: configuration taken (learned layer: %s, %u lines)", cfg.learned > 0 ? "in effect" : "none", cfg.learned_lines);
  poke(wake_pipe[1]);
}

static void control_step_locked(void);
void control_step(void) {
  pthread_mutex_lock(&ctl_mx);
  if (!sleeping) control_step_locked();
  pthread_mutex_unlock(&ctl_mx);
}

static void force_smc(const char *why) {
  if (st.mode != M_SMC || fs_get() != 0) { smc_auto(); shm->forced = 0; set_mode(M_SMC, why); }
}

static void control_step_locked(void) {
  double now = now_s();
  double dt = st.last_step > 0 ? now - st.last_step : DT_FAST;
  if (dt > 60) dt = 60;
  st.last_step = now;
  st.full = st.dt <= DT_FAST || now - st.last_full >= FULL_EVERY;
  if (st.full) st.last_full = now;
  st.dt = DT_FAST;                  // every early return below (fault, trip, smc, wake) samples fast
  read_sensors(now);
  double c, g; load_now(now, &c, &g);
  // feed-forward smoothing: rise with tau 20 s, fall with tau 120 s (no pumping on short spikes)
  if (!isnan(c) && c - st.cpu_ema > 0.25) st.fast_until = now + 60;   // CPU load jump (> 1 core)
  if (!isnan(g) && g - st.gpu_ema > 0.25) st.fast_until = now + 60;   // GPU load jump
  if (!isnan(c)) { double tau = c > st.cpu_ema ? 20.0 : 120.0; st.cpu_ema += (c - st.cpu_ema) * (1 - exp(-dt / tau)); }
  if (!isnan(g)) { double tau = g > st.gpu_ema ? 20.0 : 120.0; st.gpu_ema += (g - st.gpu_ema) * (1 - exp(-dt / tau)); }
  double vol; int prof = profile_now(now, &vol);
  pthread_mutex_lock(&hint_mx); double hchg = hint.changed_at; pthread_mutex_unlock(&hint_mx);
  if (now - hchg < 60) st.fast_until = hchg + 60;                    // context change: 60 s fast
  double shift = cfg.prof[prof].base + cfg.prof[prof].vol * vol;
  update_level();

  if (st.mode == M_DISABLED) { if (fs_get() != 0) smc_auto(); publish(prof, shift); return; }
  if (pm_failed) { force_smc("no sleep notifications - SMC regulates"); publish(prof, shift); return; }

  // ---- after a wake: hint and drive reading are from before the sleep (monotonic time stood
  // still), so drop them and wait for fresh values under SMC control
  if (woke_at >= 0) {
    pthread_mutex_lock(&hint_mx); hint.until = 0; pthread_mutex_unlock(&hint_mx);
    if (hdd_read_at() < woke_at + 1) {
      force_smc("after wake, waiting for fresh sensors");
      for (int n = 0; n < MAX_FANS; n++) st.fs[n].out = isnan(st.ac[n]) ? 0 : st.ac[n];
      if (now - woke_at < cfg.hdd_stale) { publish(prof, shift); return; }
    }
    woke_at = -1;
  }
  // ---- faults -> SMC
  int bad = -1, over = -1;
  for (int i = 0; i < cfg.nsens; i++) {
    if (!st.temp_ok[i]) { if (bad < 0) bad = i; }
    else if (st.temp[i] >= cfg.sens[i].trip && over < 0) over = i;
  }
  if (bad >= 0 && !strcmp(cfg.sens[bad].key, HDD_KEY) && hdd_never_read() && now - st.started < cfg.hdd_stale) {
    force_smc("waiting for the first drive reading");
    publish(prof, shift); return;
  }
  if (st.mode == M_TRIP && now < st.trip_until) {
    // hold: either SMC (fault) or all fans at max (temperature) - re-assert, nothing else
    if (strncmp(st.reason, "limit", 5) == 0) {
      int mask = 0;
      st.full = 1;                   // trip hold (rare): write and verify everything each step
      for (int n = 0; n < st.fan_count; n++) if (cfg.fan[n].used) { if (put_tg(n, cfg.fan[n].max, 1)) { fault("SMC write failed", now); publish(prof, shift); return; } mask |= 1 << n; }
      if (put_fs(mask, 1)) fault("SMC write failed", now);
      else shm->forced = mask;
    } else { if (fs_get() != 0) smc_auto(); shm->forced = 0; }
    publish(prof, shift); return;
  }
  // a healthy sensor over its trip wins over another unreadable one: max cooling
  if (over >= 0) {
    char w[96]; snprintf(w, sizeof w, "limit %s %.1f >= %.1f, all fans max", cfg.sens[over].key, st.temp[over], cfg.sens[over].trip);
    set_mode(M_TRIP, w); st.trip_until = now + cfg.trip_hold;
    ident_end("temperature limit");
    int mask = 0;
    st.full = 1;
    for (int n = 0; n < st.fan_count; n++) if (cfg.fan[n].used) { if (put_tg(n, cfg.fan[n].max, 1)) { fault("SMC write failed", now); publish(prof, shift); return; } mask |= 1 << n; st.fs[n].out = cfg.fan[n].max; }
    if (put_fs(mask, 1)) fault("SMC write failed", now);
    else { shm->forced = mask; shm->trip_max = 1; shm->trip_until = st.trip_until; }
    publish(prof, shift); return;
  }
  if (bad >= 0) { char w[96]; snprintf(w, sizeof w, "sensor %s unreadable", cfg.sens[bad].key); fault(w, now); publish(prof, shift); return; }
  // a trip ends only once everything is 3 C below its trip point
  if (st.mode == M_TRIP) {
    for (int i = 0; i < cfg.nsens; i++) if (st.temp[i] >= cfg.sens[i].trip - 3) { st.trip_until = now + 30; publish(prof, shift); return; }
  }

  // ---- curves
  int mask = 0;
  double tier = DT_CALM;            // sampling for the next step: the most demanding fan/sensor wins
  int deep = 1;                     // deep calm: nothing within 8 C of anything
  for (int i = 0; i < cfg.nsens; i++) if (st.temp_ok[i] && st.temp[i] >= cfg.sens[i].warn - 8) deep = 0;
  for (int i = 0; i < cfg.nsens; i++) if (st.temp_ok[i] && st.temp[i] >= cfg.sens[i].warn - 5) tier = st.temp[i] >= cfg.sens[i].warn - 2 ? DT_FAST : (tier > DT_NEAR ? DT_NEAR : tier);
  // identification: ends on its own conditions before the fans are computed
  if (st.force_tag[0]) {
    if (now >= st.force_until) ident_end("done");
    else if (prof != P_RUHE && !dry) ident_end("Sofa no longer rests");
    else for (int i = 0; i < cfg.nsens; i++) if (st.temp[i] >= cfg.sens[i].warn - 3) { char w[64]; snprintf(w, sizeof w, "%s %.1f near warn", cfg.sens[i].key, st.temp[i]); ident_end(w); break; }
  }
  for (int n = 0; n < st.fan_count; n++) {
    fan_cfg_t *fc = &cfg.fan[n];
    if (!fc->used) continue;
    fanstep_t r;
    policy_fan(&cfg, n, st.temp, st.cpu_ema, st.gpu_ema, shift, now, dt, st.force_tag[0] ? st.force[n] : -1, &st.fs[n], &r);
    if (r.near_start && tier > DT_NEAR) tier = DT_NEAR;
    if (r.hot) deep = 0;
    if (r.started) st.stall_since[n] = 0;
    if (r.moving) tier = DT_FAST;
    double next = r.next;
    if (put_tg(n, (int)lround(next), st.full)) { fault("SMC write failed", now); publish(prof, shift); return; }
    mask |= 1 << n;
    // a fan told to turn must turn: after a 15 s start window, below half the target for 20 s -> fault
    if (!dry && next > 0 && now - st.fs[n].on_since > 15 && (isnan(st.ac[n]) || st.ac[n] < next / 2)) {
      if (st.stall_since[n] <= 0) st.stall_since[n] = now;
      else if (now - st.stall_since[n] > 20) { char w[96]; snprintf(w, sizeof w, "fan %d stalled (%.0f rpm, wanted %.0f)", n, st.ac[n], next); fault(w, now); publish(prof, shift); return; }
    } else st.stall_since[n] = 0;
  }
  int pf = put_fs(mask, st.full);
  if (pf == -2) {                    // FS! was changed from outside: write everything again now
    logf_("FS! changed from outside - targets written again");
    for (int n = 0; n < st.fan_count; n++) if (cfg.fan[n].used && put_tg(n, (int)lround(st.fs[n].out), 1)) { fault("SMC write failed", now); publish(prof, shift); return; }
    pf = put_fs(mask, 1);
    tier = DT_FAST;
  }
  if (pf) { fault("SMC write failed", now); publish(prof, shift); return; }
  shm->forced = mask;
  if (st.mode != M_CURVE) { set_mode(M_CURVE, "curves"); tier = DT_FAST; }
  for (int n = 0; n < st.fan_count; n++) if (st.fs[n].out > 0) deep = 0;
  if (prof == P_PLAYBACK) deep = 0;                                  // playback: never the 20 s tier
  st.dt = (tier >= DT_CALM && deep) ? DT_DEEP : tier;
  if (now < st.fast_until) st.dt = DT_FAST;
  if (st.force_tag[0] && st.dt > DT_NEAR) st.dt = DT_NEAR;          // identification: sample closely
  publish(prof, shift);
}
