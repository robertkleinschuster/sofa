// sofa-fand - internal interfaces between the modules (one binary, see README "Architecture").
//
//   smc.c      SMC transport: key read/write, temperatures, FS!/F<n>Tg, return to SMC control
//   machine.c  what this Mac has, discovered from the SMC: fans, temperature keys, Apple's limits
//   cfg.c      the configuration: reference (policy, root) + learned layer, parsed and validated
//   log.c      RAM log ring + syslog thread, guard -> controller log lines
//   sysmon.c   helper threads: SMART drive temperature, CPU/GPU load, system sleep/wake
//   control.c  the control step (curves, floors, ramps, trips, faults), published state
//   policy.c   the fan decision as a pure function (controller + the learner's simulator)
//   record.c   the recorder: rows for the learner, written by its own thread
//   sock.c     Sofa's hint/state datagrams and the ctl stream socket
//   daemon.c   guard + controller processes, reload, CLI
//   learn*.c   the nightly learner (learn.h)
#ifndef SOFA_FAND_H
#define SOFA_FAND_H

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <stdio.h>
#include <sys/types.h>

// the dry run (-n) uses its own directory, so it never takes the installed daemon's sockets
#define RUN_DIR      (dry ? "/var/run/sofa-fand-dry" : "/var/run/sofa-fand")
#define HINT_SOCK    (dry ? "/var/run/sofa-fand-dry/hint.sock" : "/var/run/sofa-fand/hint.sock")
#define CTL_SOCK     (dry ? "/var/run/sofa-fand-dry/ctl.sock" : "/var/run/sofa-fand/ctl.sock")
#define CONF_PATH    "/usr/local/etc/sofa-fand.conf"      // reference: policy + curves (root, hand-made)
#define LEARNED_DIR  "/var/db/sofa-fand"                  // root 0755
#define LEARNED_PATH "/var/db/sofa-fand/learned.conf"     // learned layer, installed by `sofa-fand apply`
#define DATA_DIR     "/var/db/sofa-fand/data"             // the recorder's rows (record.c), the learner's input
#define STATE_DIR    "/var/db/sofa-fand"                  // learner: trial, history, report

#define MAX_FANS     6       // FS! is a bit mask; the iMac12,2 has 3
#define MAX_SENS     40
#define MAX_PTS      8
#define MAX_CURVES   12
#define MAX_FLOORS   16
#define HDD_KEY      "HDD"   // not an SMC key: SMART attribute 194 of the first drive
#define HINT_MAX     512

// Adaptive sampling (each SMC transaction costs ~25 kernel wakeups on the iMac12,2, measured with
// dtrace 2026-11-18: 540 wakeups/s at a fixed 2 s loop over 20 sensors).
#define DT_FAST      2.0     // fans moving, a sensor near warn, trip/fault/start/wake: everything every 2 s
#define DT_NEAR      5.0     // a stopped fan close to its curve start, or a sensor within 5 C of warn
#define DT_CALM      10.0    // fans stable, everything far from thresholds
#define DT_DEEP      20.0    // all fans stopped and every sensor >= 8 C below its curve start and warn
#define FULL_EVERY   120.0   // non-"fast" sensors, stopped fans, FS! check
#define GUARD_STALE  45.0    // > DT_DEEP + a slow step (sensor retries)

// ==================================================================================== smc.c
extern int dry;              // -n: compute and report, never write the SMC (FS!/F<n>Tg)
int    smc_open(void);
int    smc_read(const char *key, unsigned char *buf, UInt32 *size, UInt32 *type);
int    smc_key_count(void);                       // #KEY, -1 on error
int    smc_key_at(int index, char key[5]);        // READ_INDEX
int    smc_temp(const char *key, double *t);      // sp78, plausible 5..125 C, one retry
int    smc_fpe2(const char *key, double *v);
int    smc_sp78(const char *key, double *v);      // any sp78 value (thresholds), no range check
int    smc_num(const char *key, double *v);       // any numeric type (power keys)
int    fs_get(void);
int    fs_set(int mask);
int    tg_set(int fan, int rpm);
int    smc_auto(void);       // FS! = 0, verified; failing that every fan to its maximum
void   smc_forget_writes(void);                   // next writes go out unconditionally
int    put_tg(int fan, int rpm, int full);        // cached: only changes reach the SMC (full: always)
int    put_fs(int mask, int full);                // 0 ok, -1 error, -2 changed from outside
void   smc_set_fan_max(int fan, int rpm);         // what smc_auto forces if FS! cannot be cleared
UInt32 k2u(const char *s);
int    key_ok(const char *k);
double now_s(void);                               // monotonic seconds

// ================================================================================ machine.c
// What this Mac has. Discovered once per process from the SMC; nothing in it is configured.
typedef struct {
  char key[5];
  double fan_start, warn, throttle, shutdown;   // Apple's S<xy>F/W/P/S for this sensor, 0 = none
  double target;                                // Apple's control target (SGTg, SCTg, ...), 0 = none
} msens_t;
typedef struct {
  int ok; char err[120];
  int nfans;
  struct { char name[8]; int min, max; } fan[MAX_FANS];   // F<n>ID name, F<n>Mn, F<n>Mx
  int nsens; msens_t sens[96];                            // every readable temperature key
  char model[32];                                         // hw.model, e.g. iMac12,2
  char pw_total[5], pw_cpu[5], pw_gpu[5];                 // SMC power keys (W) the learner's model uses, "" = none
  char ambient[5];                                        // the ambient temperature key (TA0P), "" = none
} machine_t;
extern machine_t machine;
int  machine_discover(machine_t *m);
void machine_print(FILE *o, const machine_t *m);
const msens_t *machine_sensor(const machine_t *m, const char *key);   // NULL: no such temperature key

// ==================================================================================== cfg.c
typedef enum { FF_NONE, FF_CPU, FF_GPU, FF_BOTH } ff_t;
typedef struct { double t; double rpm; } pt_t;
typedef struct { int sensor; int npts; pt_t pts[MAX_PTS]; double shift; int learned; } curve_t;   // shift: learned, + = later/quieter
typedef struct { int sensor; double temp; int rpm; int machine; } floor_t;   // machine: Apple-minimum floor from the SMC
typedef struct { char key[5]; double trip, warn; ff_t ff; int fast; double target; } sens_cfg_t;   // target: what the learner aims below (steady state)
typedef struct {
  int used; char name[8];
  int max, minrun;                // max rpm; lowest rpm the fan runs stable at (0 < x < minrun -> minrun)
  double hyst;                    // deg C: falling demand is computed at T + hyst
  double up, down;                // ramp limits, rpm per second
  int minon, minoff;              // s: once started stay on / once stopped stay off (unless warn/floor)
  double pw, fw;                  // weight of the profile shift / of the feed-forward for this fan
  double loud;                    // how much this fan's noise counts for the learner (1 = normal)
  int ncurves; curve_t curves[MAX_CURVES];
  int nfloors; floor_t floors[MAX_FLOORS];
} fan_cfg_t;
enum { P_DEFAULT, P_RUHE, P_IDLE, P_PLAYBACK, P_COUNT };
enum { LEARN_FREE, LEARN_COOLER };   // a learned profile may go either way / only cooler than the reference
typedef struct { double base, vol; int learn; double noise; } prof_t;   // shift: base + vol * volume; noise: how much quiet matters here (learner)
extern const char *prof_name[P_COUNT];
typedef struct {
  int nsens; sens_cfg_t sens[MAX_SENS];
  fan_cfg_t fan[MAX_FANS];
  prof_t prof[P_COUNT];
  double ff_cpu, ff_gpu;          // deg C added at full load
  double gpu_full;                // PM4 commands/s that count as full GPU load
  int hdd_interval, hdd_stale, trip_hold, allow_uid;
  char reply_dir[128];
  int ok; char err[200];
  int learned;                    // 0 none, 1 applied, -1 refused (err_learned says why)
  char err_learned[200];
  unsigned learned_lines;         // learned lines in effect
} cfg_t;
extern cfg_t cfg;                 // the controller's (swapped in place on reload, under ctl_mx)
int  cfg_load(cfg_t *c, const char *ref, const char *learned, const machine_t *m);   // learned may be NULL
void cfg_print(FILE *o, const cfg_t *c);
int  sens_index(const cfg_t *c, const char *key);
double interp(const curve_t *c, double t);
double curve_demand(const cfg_t *c, int fan, int k, double temp);   // rpm of curve k at temp, learned shift applied
int  learned_check(const cfg_t *eff, const cfg_t *ref, char *err, size_t cap);   // every safety rule of the learned layer
void learned_write(FILE *o, const cfg_t *eff, const cfg_t *ref);                 // eff as learned-layer lines over ref
#define MAX_SHIFT 8.0

// ================================================================================= policy.c
typedef struct { double out, on_since, off_since; } fanstate_t;      // one fan's state between steps
typedef struct { double next; int started, moving, near_start, hot, urgent; } fanstep_t;
// One fan, one step. temp[] by the configuration's sensor index (all valid), cpu/gpu = smoothed
// load 0..1, shift = profile shift, force >= 0: hold this speed (identification), else curves.
void policy_fan(const cfg_t *c, int n, const double *temp, double cpu, double gpu, double shift,
                double now, double dt, double force, fanstate_t *fs, fanstep_t *r);

// ==================================================================================== log.c
void logf_(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void *log_thread(void *arg);
void log_start_threaded(void);
void guard_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void log_recent(void (*out)(const char *line, void *ctx), void *ctx, unsigned n);

// Guard <-> controller page. The guard never calls syslog synchronously once the controller
// runs: it appends to glog[] and the controller's log thread passes the lines on.
#define GLOG_LINES 16
typedef struct {
  volatile double beat; volatile int forced;          // controller -> guard
  volatile double beat_due;                           // controller: next beat expected by then
  volatile double trip_until; volatile int trip_max;  // survives a controller restart
  volatile int sleeping;                              // between WillSleep and HasPoweredOn
  volatile unsigned glog_head, glog_printed; char glog[GLOG_LINES][160];   // guard -> controller log thread
} shared_t;
extern shared_t *shm;
// The guard reloads the configuration on SIGHUP and hands it to the running controller through
// this page (seqlock: gen odd while written). No restart, so the fans never fall back to the SMC.
typedef struct { volatile unsigned gen; cfg_t cfg; } shcfg_t;
extern shcfg_t *shcfg;

// ================================================================================= sysmon.c
void *smart_thread(void *arg);
void *load_thread(void *arg);
void *power_thread(void *arg);
int  hdd_reading(double now, double stale, double *t);   // 1 fresh value
int  hdd_never_read(void);
double hdd_read_at(void);
int  load_now(double now, double *cpu, double *gpu);      // 1: values younger than 10 s
void power_sleep(void);
void power_wake(void);
extern volatile int pm_failed;   // no sleep notifications: never force fans

// ================================================================================ control.c
enum { M_CURVE, M_SMC, M_TRIP, M_DISABLED };
extern const char *mode_name[];
// Controller -> socket thread (snapshot, under pub_mx). It carries what the socket thread needs of
// the configuration too, so a reload never changes cfg under a reader in another thread.
typedef struct {
  int level, mode, profile; unsigned level_seq;
  int nsens; char key[MAX_SENS][5]; double warn[MAX_SENS], trip[MAX_SENS]; ff_t ff[MAX_SENS];
  double temp[MAX_SENS]; int temp_ok[MAX_SENS];
  int fan_used[MAX_FANS]; char fan_name[MAX_FANS][8];
  double ac[MAX_FANS], target[MAX_FANS];
  double cpu, gpu, shift;
  char reason[96];
  int learned; unsigned learned_lines; char err_learned[120];
  unsigned cfg_gen;               // reloads taken
  char reply_dir[128]; int allow_uid;
  char ident[24]; double ident_left;   // identification step running (tag), seconds left
} pub_t;
typedef struct { int ctx; double vol; double until; int pid; unsigned count; double changed_at; } hint_t;
extern pub_t pub; extern pthread_mutex_t pub_mx;
extern hint_t hint; extern pthread_mutex_t hint_mx;
extern pthread_mutex_t ctl_mx;   // control step vs. power events vs. reload
extern volatile int sleeping;
extern volatile double woke_at;
extern int wake_pipe[2], push_pipe[2];
void poke(int fd);
void control_init(double now);
void control_step(void);
double control_next_dt(void);
int  control_fan_count(void);
void control_after_wake(void);
void control_take_cfg(const cfg_t *n);    // reload: swap the configuration in place
int  control_ident(const int *rpm, int nfans, double secs, const char *tag, char *err, size_t cap);   // rpm -1: curves
void control_ident_stop(void);
unsigned long control_locked_kb(void);
void control_set_locked_kb(unsigned long kb);
double control_started(void);

// ================================================================================== record.c
void *record_thread(void *arg);
void record_flush(void);
void record_request_flush(void);   // the recorder thread writes within ~20 s (reload, ctl FLUSH)

// ==================================================================================== sock.c
extern int lfd_hint, lfd_ctl;
void *socket_thread(void *arg);
int  parse_hint(const char *msg, double *vol, double *ttl, int *pid);   // profile index or -1

#endif
