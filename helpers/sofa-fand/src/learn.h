// The learner (`sofa-fand learn`, nightly, root): data -> thermal model -> simulated controller ->
// one small, checked step -> applied as the learned layer -> judged on measured data -> kept or
// rolled back; then one block of identification steps while Sofa rests.
//
//   learn_data.c    the recorder's CSV rows -> one-minute bins; measured metrics per mode
//   learn_model.c   grey-box thermal model per sensor (NNLS), free-run validation on held-out chunks
//   learn_sim.c     scenarios from the data, closed-loop simulation through policy_fan, cost
//   learn_search.c  coordinate search for the next step within the nightly limits
//   learn_trial.c   trial state, measured judgement, rejected steps, history
//   learn_ident.c   identification steps through the daemon's IDENT command
//   learn_init.c    Apple-equivalent reference for any Mac, quiet bootstrap from the model
//   learn.c         `sofa-fand learn` / `init` / `migrate`
#ifndef SOFA_FAND_LEARN_H
#define SOFA_FAND_LEARN_H
#include "fand.h"

#define LEARN_DAYS    30       // data the model is fitted on
#define MODE_N        4
enum { MD_RUHE, MD_IDLE, MD_PLAY, MD_TEST };
extern const char *mode_label[MODE_N];
#define TESTS_CSV     DATA_DIR "/tests.csv"   // start,end,tag: identification intervals of migrated data
#define REPORT_PATH   STATE_DIR "/report.md"
#define HISTORY_PATH  STATE_DIR "/history.log"
#define TRIAL_PATH    STATE_DIR "/trial"
#define REJECTED_PATH STATE_DIR "/rejected"
#define IDENT_STATE   STATE_DIR "/ident.next"

// one minute of data (means), sensors by the configuration's index; NAN = unknown
typedef struct {
  double t;                    // epoch of the minute
  int prof, curve, test;       // P_* (-1 unknown); the daemon regulated by its curves; an identification minute
  double vol, cpu, gpu;
  double fan[MAX_FANS];        // actual rpm
  double pc, pg, pr;           // power W: CPU package, GPU, rest of the machine (proxies if the Mac has no keys)
  double amb;
  double temp[MAX_SENS];
} bin_t;
typedef struct { bin_t *b; int n; } series_t;
int  data_load(series_t *s, const cfg_t *c, const machine_t *m, const char *dir, double since);
void data_free(series_t *s);
int  bin_mode(const bin_t *b);                     // MD_* or -1
int  bin_inputs(const bin_t *b, const cfg_t *c);   // power, ambient and every used fan known
int  bin_next(const series_t *s, int i);           // the following minute exists

typedef struct {
  double minutes, noise, amb;  // noise: mean of sum(loud * (rpm/1000)^2)
  double p95[MAX_SENS];        // 95 % value of T - ambient (NAN: no data)
  double warn_min;             // minutes with a sensor at or above warn
} metric_t;
void measure(metric_t out[MODE_N], const series_t *d, const cfg_t *c, double from, double to);
double fan_noise(const cfg_t *c, const double *rpm);

// ------------------------------------------------------------------------------ model
// T = N + rg*Pg + rc*Pc; dN/dt [C/min] = a0 + h_cpu*Pc/10 + h_gpu*Pg/10 + h_rest*Pr/10 - (k0 + sum_f k_f*rpm_f/1000)*(N - Tamb)
#define NPAR (5 + MAX_FANS)
#define R_MAX  0.6             // instant offsets searched: 0 .. R_MAX C/W in R_STEP, then R_STEP/2 around the best
#define R_STEP 0.1
typedef struct {
  int ok, fixed;               // fitted and validated / held at ambient (the ambient sensor itself)
  int npts;
  double th[NPAR];
  double rg, rc;               // instant offset of the sensor over its node, C/W of GPU / CPU power
  double rmse[MODE_N]; double vmin[MODE_N];   // free-run validation on held-out 2 h chunks (minutes)
  double rmse_all, err90, errmax;
  double steady_lo, steady_hi; // measured T - ambient, 10 % / 95 % (start points for the simulation)
} smodel_t;
typedef struct { smodel_t s[MAX_SENS]; int nfans; } model_t;
void   model_fit(model_t *m, const series_t *d, const cfg_t *c, const machine_t *mc);
double model_rate(const smodel_t *s, int nfans, double N, double amb, double pc, double pg, double pr, const double *rpm);   // dN/dt per minute
double model_offset(const smodel_t *s, double pc, double pg);   // sensor = node + this
double gate_rmse(const cfg_t *c, int si);   // the validation error a sensor's model may have
int    sensor_steers(const cfg_t *c, int si);   // a curve or floor reads this sensor
// may the learner make anything quieter? (every steering sensor validated in every use mode)
int    model_trusted(const model_t *m, const cfg_t *c, char *why, size_t cap);
// does this sensor's model count in this mode? (validated: >= 120 min, error within its gate)
int    sens_trusted(const model_t *m, const cfg_t *c, int s, int md);

// --------------------------------------------------------------------------- simulation
typedef struct {
  char name[48]; int prof, md; double weight;
  double vol, cpu, gpu, pc, pg, pr, amb;
  double minutes;
} scen_t;
#define MAX_SCEN 12
int scenarios(scen_t *out, const series_t *d, const cfg_t *c);
typedef struct { double peak[MAX_SENS]; double rpm[MAX_FANS], on[MAX_FANS], starts[MAX_FANS]; double noise; } simres_t;
void simulate(const cfg_t *c, const model_t *m, const scen_t *sc, int hot, simres_t *r);
// cost of a configuration over every scenario (res: per scenario, cold and hot start merged)
double cost(const cfg_t *c, const model_t *m, const scen_t *sc, int nsc, simres_t *res, double *penalty);   // penalty: the temperature part

// ------------------------------------------------------------------------------ search
typedef struct {
  int ok; char why[400];       // a step was found and passed every check / why not
  cfg_t eff;                   // the effective configuration with the step
  double cost_now, cost_step, cost_best, pen_now, pen_step;   // total and its temperature part
  char text[1024];             // the step in words
  char kind[16];               // quieter, cooler, mixed
  char keys[256];              // its components ("f2/Tp2H/+ p/ruhe/-"), for the rejected list
} step_t;
void search_step(step_t *st, const cfg_t *cur, const cfg_t *ref, const model_t *m,
                 const scen_t *sc, int nsc, FILE *rep);

// ------------------------------------------------------------------------------ trial
// One applied change is on trial until the measured data judge it; no new change meanwhile.
typedef struct { int active; double applied; char kind[16]; char keys[256]; char what[1024]; } trial_t;
int  trial_load(trial_t *t);
int  trial_save(const trial_t *t);
void history(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
// 1 keep, -1 roll back (why), 0 not yet
int  trial_judge(const trial_t *t, const series_t *d, const cfg_t *c, char *why, size_t cap, FILE *rep);
int  rejected_recently(const char *key);
void rejected_add(const char *keys);

// ---------------------------------------------------------------------------- identification
int  ident_night(const cfg_t *c, const machine_t *m, FILE *rep, int dry_run);

// ------------------------------------------------------------------------------ reference
#define INIT_MARK "# sofa-fand init"
int  init_reference(FILE *o, const machine_t *m);
int  bootstrap_reference(FILE *o, const cfg_t *ref, const model_t *m, const machine_t *mc);

int  learn_main(int argc, char **argv);
int  init_main(int argc, char **argv);
int  migrate_main(int argc, char **argv);

// daemon.c
int  ctl_request(const char *cmd, char *out, size_t cap);      // 0 ok (out: the answer)
int  learned_install(const char *file, const char *conf);      // validate + install + reload (0 ok)
int  learned_rollback(void);
int  reload_daemon(void);
int  load_machine_quiet(void);
#endif
