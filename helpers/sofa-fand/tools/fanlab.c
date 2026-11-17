// fanlab - supervised fan measurements on the iMac12,2 (root for anything that forces fans).
//   fanlab rec  DUR                      record only (SMC regulates)
//   fanlab step DUR F0 F1 F2             force fans (rpm or 'a' = SMC) for up to DUR s; with
//                                        MINEQ=s set: stop early once all temps are flat
//   fanlab burn THREADS PCT DUR          synthetic CPU load (duty cycle PCT %), nice it yourself
//   fanlab watchdog HBFILE STALE DONEFILE  reset FS!=0 whenever HBFILE is older than STALE s
// Env: CSV=file (append samples), LIVE=file (human log), TEST="Test x/N" (prefix), HB=file
//      (touched every sample), LOADLBL=text, LIM_GPU/LIM_CPU/LIM_HDD/LIM_ODD/LIM_PSU (deg C).
// Every exit path (end, limit, error, signal) writes FS! = 0 and verifies it.
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/ata/ATASMARTLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <time.h>
#include <math.h>
#include <stdarg.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <utime.h>

typedef struct { char major, minor, build, reserved[1]; UInt16 release; } vers_t;
typedef struct { UInt16 version, length; UInt32 a, b, c; } plimit_t;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } keyinfo_t;
typedef struct { UInt32 key; vers_t vers; plimit_t p; keyinfo_t keyInfo; char result, status, data8; UInt32 data32; unsigned char bytes[32]; } K;
static io_connect_t c;
static UInt32 k2u(const char *s) { return ((UInt32)s[0]<<24)|((UInt32)s[1]<<16)|((UInt32)s[2]<<8)|(UInt32)s[3]; }
static int call(K *i, K *o) { size_t s = sizeof(K); return IOConnectCallStructMethod(c, 2, i, sizeof(K), o, &s) ? -1 : 0; }
static int rd(const char *k, unsigned char *b) {
  K i, o; memset(&i, 0, sizeof i); memset(&o, 0, sizeof o); i.key = k2u(k); i.data8 = 9;
  if (call(&i, &o) || o.result) return -1;
  i.keyInfo.dataSize = o.keyInfo.dataSize; i.data8 = 5; memset(&o, 0, sizeof o);
  if (call(&i, &o) || o.result) return -1;
  memcpy(b, o.bytes, 4); return 0;
}
static int wr(const char *k, const unsigned char *b, UInt32 n) {
  K i, o; memset(&i, 0, sizeof i); memset(&o, 0, sizeof o); i.key = k2u(k); i.data8 = 6; i.keyInfo.dataSize = n; memcpy(i.bytes, b, n);
  if (call(&i, &o) || o.result) return -1; return 0;
}
static double temp(const char *k) { unsigned char b[4]; if (rd(k, b)) return NAN; double v = (signed char)b[0] + b[1] / 256.0; return (v < 5 || v > 125) ? NAN : v; }
static double rpm(const char *k) { unsigned char b[4]; if (rd(k, b)) return NAN; return ((b[0] << 8) | b[1]) / 4.0; }
static int fsval(void) { unsigned char b[4]; if (rd("FS! ", b)) return -1; return (b[0] << 8) | b[1]; }
static int setfs(int m) { unsigned char b[2] = { (unsigned char)(m >> 8), (unsigned char)m }; return wr("FS! ", b, 2); }
static int settg(int f, int r) { char k[5]; snprintf(k, 5, "F%dTg", f); unsigned char b[2] = { (unsigned char)((r << 2) >> 8), (unsigned char)((r << 2) & 0xff) }; return wr(k, b, 2); }
static int reset(void) { for (int i = 0; i < 3; i++) if (setfs(0) == 0 && fsval() == 0) return 0; return -1; }
static void onsig(int s) { setfs(0); setfs(0); _exit(128 + s); }
static void atexit_reset(void) { reset(); }

// ---- SMART (thread, so a stuck drive never stalls the safety loop)
static volatile int hdd_t = -1; static volatile time_t hdd_at;
static int smart_read(void) {
  // Open, read, close every time: the SMART user client is exclusive (smartctl fails while
  // anyone holds it), so it must never stay open between reads.
  io_iterator_t it; io_object_t o; int r = -1, done = 0;
  if (IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IOBlockStorageDevice"), &it)) return -1;
  while ((o = IOIteratorNext(it))) {
    CFTypeRef cap = IORegistryEntrySearchCFProperty(o, kIOServicePlane, CFSTR("SMART Capable"), kCFAllocatorDefault, 0);
    if (cap && !done) {
      IOCFPlugInInterface **pi = 0; SInt32 sc; IOATASMARTInterface **si = 0;
      if (!IOCreatePlugInInterfaceForService(o, kIOATASMARTUserClientTypeID, kIOCFPlugInInterfaceID, &pi, &sc) && pi) {
        (*pi)->QueryInterface(pi, CFUUIDGetUUIDBytes(kIOATASMARTInterfaceID), (LPVOID *)&si);
        if (si) {
          ATASMARTData d;
          if (!(*si)->SMARTReadData(si, &d)) {
            unsigned char *b = (unsigned char *)&d;
            for (int i = 0; i < 30; i++) { unsigned char *a = b + 2 + i * 12; if (a[0] == 194) { r = a[5]; break; } }
          }
          (*si)->Release(si);
        }
        IODestroyPlugInInterface(pi);
        done = 1;
      }
    }
    if (cap) CFRelease(cap);
    IOObjectRelease(o);
  }
  IOObjectRelease(it);
  return r;
}
static void *smart_thr(void *x) { (void)x; for (;;) { int t = smart_read(); if (t > 5 && t < 90) { hdd_t = t; hdd_at = time(0); } sleep(20); } return 0; }

// ---- load: CPU % (sum over cores, 0..400) and GPU PM4 command rate
static double cpu_pct(void) {
  static unsigned long long last_busy, last_tot;
  natural_t n; processor_info_array_t info; mach_msg_type_number_t cnt;
  if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt)) return NAN;
  unsigned long long busy = 0, tot = 0;
  for (natural_t i = 0; i < n; i++) {
    unsigned int *t = (unsigned int *)&info[i * CPU_STATE_MAX];
    busy += t[CPU_STATE_USER] + t[CPU_STATE_SYSTEM] + t[CPU_STATE_NICE];
    tot += t[CPU_STATE_USER] + t[CPU_STATE_SYSTEM] + t[CPU_STATE_NICE] + t[CPU_STATE_IDLE];
  }
  vm_deallocate(mach_task_self(), (vm_address_t)info, cnt * sizeof(integer_t));
  double r = (last_tot && tot > last_tot) ? 100.0 * n * (busy - last_busy) / (tot - last_tot) : NAN;
  last_busy = busy; last_tot = tot; return r;
}
static double gpu_rate(void) {
  static long long last; static double last_t;
  io_iterator_t it; io_object_t o; long long v = -1;
  if (IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IOAccelerator"), &it)) return NAN;
  while ((o = IOIteratorNext(it))) {
    CFDictionaryRef ps = IORegistryEntryCreateCFProperty(o, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
    if (ps) {
      CFNumberRef nr = CFDictionaryGetValue(ps, CFSTR("HWChannel PM4 | Commands Completed"));
      if (nr && v < 0) CFNumberGetValue(nr, kCFNumberLongLongType, &v);
      CFRelease(ps);
    }
    IOObjectRelease(o);
  }
  IOObjectRelease(it);
  struct timeval tv; gettimeofday(&tv, 0); double t = tv.tv_sec + tv.tv_usec / 1e6;
  double r = (last > 0 && v >= last && t > last_t) ? (v - last) / (t - last_t) : NAN;
  last = v; last_t = t; return r;
}

// ---- logging
static const char *T[] = { "TA0P","TC0P","TC0H","TCXc","TC0c","TC1c","TC2c","TC3c","TG0D","TG0H","TO0P",
                           "Tp1P","Tp2H","Tp3H","TPCD","Tm0P","TL0P","TS0P","TS2P" };
#define NT (int)(sizeof T / sizeof T[0])
static FILE *csv, *live;
static const char *tst = "", *lbl = "";
static void livef(const char *fmt, ...) {
  if (!live) return;
  char ts[16]; time_t t = time(0); strftime(ts, sizeof ts, "%H:%M:%S", localtime(&t));
  fprintf(live, "%s %s%s", ts, tst, *tst ? ": " : "");
  va_list ap; va_start(ap, fmt); vfprintf(live, fmt, ap); va_end(ap);
  fputc('\n', live); fflush(live);
}
typedef struct { double t[NT]; double hdd, ac[3], tg[3], cpu, gpu; int fs; } sample_t;
static void sample(sample_t *s) {
  for (int i = 0; i < NT; i++) s->t[i] = temp(T[i]);
  s->hdd = (hdd_t > 0 && time(0) - hdd_at < 90) ? hdd_t : NAN;
  for (int f = 0; f < 3; f++) { char k[5]; snprintf(k, 5, "F%dAc", f); s->ac[f] = rpm(k); snprintf(k, 5, "F%dTg", f); s->tg[f] = rpm(k); }
  s->fs = fsval(); s->cpu = cpu_pct(); s->gpu = gpu_rate();
}
static int ti(const char *k) { for (int i = 0; i < NT; i++) if (!strcmp(T[i], k)) return i; return -1; }
static void csv_head(void) {
  if (!csv || ftell(csv) > 0) return;
  fprintf(csv, "epoch,test,load,mode,want0,want1,want2,fs");
  for (int f = 0; f < 3; f++) fprintf(csv, ",F%dAc,F%dTg", f, f);
  for (int i = 0; i < NT; i++) fprintf(csv, ",%s", T[i]);
  fprintf(csv, ",HDD,cpu_pct,gpu_pm4\n");
}
static void csv_row(const sample_t *s, const char *mode, const int *want) {
  if (!csv) return;
  fprintf(csv, "%ld,%s,%s,%s,%d,%d,%d,%d", (long)time(0), tst, lbl, mode, want[0], want[1], want[2], s->fs);
  for (int f = 0; f < 3; f++) fprintf(csv, ",%.0f,%.0f", s->ac[f], s->tg[f]);
  for (int i = 0; i < NT; i++) fprintf(csv, ",%.2f", s->t[i]);
  fprintf(csv, ",%.0f,%.1f,%.0f\n", s->hdd, s->cpu, s->gpu); fflush(csv);
}
static double envd(const char *k, double d) { const char *v = getenv(k); return v ? atof(v) : d; }

static int open_smc(void) {
  io_service_t svc = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSMC"));
  if (!svc) return -1; kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &c); IOObjectRelease(svc);
  return kr ? -1 : 0;
}

// ---- burn
static volatile int burn_pct;
static void *burner(void *x) {
  (void)x;
  for (;;) {
    struct timeval a, b; gettimeofday(&a, 0);
    long on = burn_pct * 1000, el;     // 100 ms period, PCT ms busy
    do { gettimeofday(&b, 0); el = (b.tv_sec - a.tv_sec) * 1000000 + (b.tv_usec - a.tv_usec); } while (el < on);
    if (burn_pct < 100) usleep((useconds_t)(100000 - on));
  }
  return 0;
}

int main(int argc, char **argv) {
  if (argc >= 5 && !strcmp(argv[1], "burn")) {
    int n = atoi(argv[2]); burn_pct = atoi(argv[3]); int dur = atoi(argv[4]);
    if (n < 1 || n > 8 || burn_pct < 1 || burn_pct > 100) return 2;
    pthread_t th; for (int i = 0; i < n; i++) pthread_create(&th, 0, burner, 0);
    sleep((unsigned)dur); return 0;
  }
  if (open_smc()) { fprintf(stderr, "AppleSMC not reachable\n"); return 1; }
  if (argc >= 5 && !strcmp(argv[1], "watchdog")) {
    const char *hb = argv[2], *done = argv[4]; int stale = atoi(argv[3]);
    signal(SIGHUP, SIG_IGN);
    for (;;) {
      struct stat st;
      if (stat(done, &st) == 0) return 0;
      int old = stat(hb, &st) != 0 || time(0) - st.st_mtime > stale;
      if (old && fsval() != 0) { reset(); FILE *l = getenv("LIVE") ? fopen(getenv("LIVE"), "a") : 0;
        if (l) { char ts[16]; time_t t = time(0); strftime(ts, sizeof ts, "%H:%M:%S", localtime(&t));
          fprintf(l, "%s WAECHTER: kein Fortschritt seit > %d s, FS!=0 gesetzt (jetzt 0x%x)\n", ts, stale, fsval()); fclose(l); } }
      sleep(10);
    }
  }
  int rec = argc >= 3 && !strcmp(argv[1], "rec");
  int step = argc >= 6 && !strcmp(argv[1], "step");
  if (!rec && !step) { fprintf(stderr, "usage: fanlab rec DUR | step DUR F0 F1 F2 | burn N PCT DUR | watchdog HB STALE DONE\n"); return 2; }
  int dur = atoi(argv[2]);
  int want[3] = { -1, -1, -1 }, mask = 0;
  if (step) for (int f = 0; f < 3; f++) if (strcmp(argv[3 + f], "a")) { want[f] = atoi(argv[3 + f]); if (want[f] < 0 || want[f] > 5500) return 2; mask |= 1 << f; }
  signal(SIGINT, onsig); signal(SIGTERM, onsig); signal(SIGHUP, SIG_IGN); signal(SIGPIPE, SIG_IGN);
  atexit(atexit_reset);
  if (getenv("CSV")) csv = fopen(getenv("CSV"), "a");
  if (getenv("LIVE")) live = fopen(getenv("LIVE"), "a");
  if (getenv("TEST")) tst = getenv("TEST");
  if (getenv("LOADLBL")) lbl = getenv("LOADLBL");
  const char *hb = getenv("HB");
  double L_GPU = envd("LIM_GPU", 75), L_CPU = envd("LIM_CPU", 68), L_CORE = envd("LIM_CORE", 90),
         L_HDD = envd("LIM_HDD", 50), L_ODD = envd("LIM_ODD", 55), L_PSU = envd("LIM_PSU", 85);
  int mineq = (int)envd("MINEQ", 0);
  csv_head();
  pthread_t th; pthread_create(&th, 0, smart_thr, 0);
  for (int i = 0; i < 30 && hdd_t < 0; i++) usleep(100000);
  cpu_pct(); gpu_rate();
  sample_t s0; sample(&s0);
  if (!step) reset();
  char wdesc[64] = "";
  if (step) { int p = 0; for (int f = 0; f < 3; f++) p += snprintf(wdesc + p, sizeof wdesc - p, "%sF%d=%s", f ? " " : "", f, want[f] < 0 ? "SMC" : argv[3 + f]); }
  livef("%s %s, Last=%s, max %d s%s", step ? "Zwang" : "Aufzeichnung (SMC)", wdesc, lbl, dur, mineq ? " (Stopp bei Gleichgewicht)" : "");
  if (step) {
    for (int f = 0; f < 3; f++) if (want[f] >= 0 && settg(f, want[f])) { livef("ABBRUCH: F%dTg schreiben fehlgeschlagen", f); return 4; }
    if (setfs(mask) || fsval() != mask) { reset(); livef("ABBRUCH: FS! schreiben fehlgeschlagen"); return 4; }
  }
  // history of the main temps for the equilibrium test (one sample / 10 s)
  enum { H = 400 }; static double hist[H][5]; int hn = 0;
  const char *hk[5] = { "TC0P", "TG0D", "Tp2H", "TO0P", "HDD" };
  time_t t0 = time(0); int rc = 0; sample_t s;
  while (time(0) - t0 < dur) {
    sample(&s);
    csv_row(&s, step ? "force" : "smc", want);
    if (hb) utime(hb, NULL);
    double cp = s.t[ti("TC0P")], gd = s.t[ti("TG0D")], od = s.t[ti("TO0P")], ps = s.t[ti("Tp2H")];
    double co = 0; for (int j = 0; j < 4; j++) { double v = s.t[ti("TC0c") + j]; if (v > co) co = v; }
    const char *why = 0; char wb[96];
    if (isnan(cp) || isnan(gd) || isnan(od) || isnan(ps)) why = "Sensor unlesbar";
    else if (isnan(s.hdd)) why = "Plattensensor veraltet";
    else if (gd >= L_GPU) { snprintf(wb, sizeof wb, "GPU %.1f °C", gd); why = wb; }
    else if (cp >= L_CPU) { snprintf(wb, sizeof wb, "CPU %.1f °C", cp); why = wb; }
    else if (co >= L_CORE) { snprintf(wb, sizeof wb, "CPU-Kern %.0f °C", co); why = wb; }
    else if (s.hdd >= L_HDD) { snprintf(wb, sizeof wb, "Platte %.0f °C", s.hdd); why = wb; }
    else if (od >= L_ODD) { snprintf(wb, sizeof wb, "ODD %.1f °C", od); why = wb; }
    else if (ps >= L_PSU) { snprintf(wb, sizeof wb, "Netzteil %.1f °C", ps); why = wb; }
    if (step && s.fs != mask) why = "FS! von aussen veraendert";
    if (why && step) { reset(); livef("ABBRUCH: %s nach %ld s, zurück auf Automatik (FS!=0x%x)", why, (long)(time(0) - t0), fsval()); rc = 3; break; }
    if (hn < H) { for (int j = 0; j < 5; j++) hist[hn][j] = !strcmp(hk[j], "HDD") ? s.hdd : s.t[ti(hk[j])]; hn++; }
    // equilibrium: after MINEQ s, every main temp changed < 0.3 C over the last 5 min (HDD: < 1)
    if (mineq && time(0) - t0 >= mineq && hn > 31) {
      int flat = 1;
      for (int j = 0; j < 5; j++) { double d = fabs(hist[hn - 1][j] - hist[hn - 31][j]); if (d > (j == 4 ? 0.9 : 0.3)) flat = 0; }
      if (flat) { livef("Gleichgewicht nach %ld s", (long)(time(0) - t0)); break; }
    }
    sleep(10);
  }
  if (rc == 0) {
    sample(&s);
    livef("Ergebnis: CPU %.1f→%.1f, GPU %.1f→%.1f, Netzteil %.1f→%.1f, ODD %.1f→%.1f, Platte %.0f→%.0f °C; Lüfter %.0f/%.0f/%.0f U/min; Last CPU %.0f %%",
          s0.t[ti("TC0P")], s.t[ti("TC0P")], s0.t[ti("TG0D")], s.t[ti("TG0D")], s0.t[ti("Tp2H")], s.t[ti("Tp2H")],
          s0.t[ti("TO0P")], s.t[ti("TO0P")], s0.hdd, s.hdd, s.ac[0], s.ac[1], s.ac[2], s.cpu);
  }
  if (reset()) { livef("FEHLER: FS! liess sich nicht zuruecksetzen!"); return 5; }
  if (step) livef("zurück auf Automatik (FS!=0x%x)", fsval());
  return rc;
}
