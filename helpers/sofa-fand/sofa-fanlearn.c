// sofa-fanlearn - passive data collector for the self-optimisation of sofa-fand (issue #2, stage 1)
//
// Reads, never writes: temperatures, fan speeds and power straight from the SMC (read-only key
// reads, no root needed), context/profile/load/drive temperature from sofa-fand's ctl socket.
// The sensor list comes from sofa-fand's STATUS (its config), so nothing is hard-wired to one iMac.
// Samples are kept in memory and appended to one CSV per day only every few hours (the HDD should
// rest), on SIGTERM/SIGINT/SIGHUP and when the buffer is large. The model is fitted on this data.
//
//   sofa-fanlearn log [-o dir] [-f flush_s]   collect (LaunchDaemon, runs as the user)
//   sofa-fanlearn once                        print the header and one sample, then exit
//
// What is logged (everything that may explain a temperature):
//  - every sample: sofa-fand mode/profile/shift/volume/load, FS!, fan actual/target, the controller's
//    sensors, the main power keys, drive temperature; display power state and backlight brightness;
//    disk bytes/operations, network bytes, page-ins/outs (deltas per second), raw CPU load, GPU
//    PM4/UVD command rates
//  - every EXT_EVERY-th sample (fewer SMC transactions): every other SMC temperature, power, voltage
//    and current key found by enumeration at start, and the ambient light sensor (blank otherwise)
// Sampling: 10 s while a fan runs or the CPU is busy, 20 s when everything is calm (each SMC
// transaction costs ~25 kernel wakeups on this machine, see sofa-fand.c).
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/ata/ATASMARTLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <dirent.h>
#include <time.h>
#include <unistd.h>

#define CTL_SOCK  "/var/run/sofa-fand/ctl.sock"
#define MAX_SENS  32
#define MAX_FANS  6
#define DT_BUSY   10
#define DT_CALM   20
#define BUF_MAX   (2 * 1024 * 1024)
#define KEEP_DAYS 60
#define MAX_EXT   160
#define EXT_EVERY 3

// ------------------------------------------------------------------------------ SMC (read only)
typedef struct { char major, minor, build, reserved[1]; UInt16 release; } smc_vers_t;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } smc_plimit_t;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } smc_keyinfo_t;
typedef struct {
  UInt32 key; smc_vers_t vers; smc_plimit_t pLimitData; smc_keyinfo_t keyInfo;
  char result; char status; char data8; UInt32 data32; unsigned char bytes[32];
} smc_data_t;
static io_connect_t smc;
static UInt32 k2u(const char *s) { return ((UInt32)(unsigned char)s[0]<<24)|((UInt32)(unsigned char)s[1]<<16)|((UInt32)(unsigned char)s[2]<<8)|(UInt32)(unsigned char)s[3]; }
static int smc_open(void) {
  io_service_t svc = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSMC"));
  if (!svc) return -1;
  kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &smc);
  IOObjectRelease(svc);
  return kr == kIOReturnSuccess ? 0 : -1;
}
static int smc_call(smc_data_t *in, smc_data_t *out) {
  size_t sz = sizeof(*out);
  return IOConnectCallStructMethod(smc, 2, in, sizeof(*in), out, &sz) == kIOReturnSuccess && sz == sizeof(*out) ? 0 : -1;
}
#define KCACHE 320
static struct { UInt32 key, size, type; } kcache[KCACHE];
static int kcache_n;
// only the read commands 9 (key info) and 5 (read bytes) are ever sent
static int smc_read(const char *key4, unsigned char *buf, UInt32 *size, UInt32 *type) {
  UInt32 k = k2u(key4); smc_data_t in, out; int c = -1;
  for (int i = 0; i < kcache_n; i++) if (kcache[i].key == k) { c = i; break; }
  if (c < 0) {
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = k; in.data8 = 9;
    if (smc_call(&in, &out)) return -1;                // transient: not cached
    if (out.result && out.result != (char)0x84) return -1;   // only kSMCKeyNotFound is cached as missing
    int miss = out.result != 0;
    if (kcache_n >= KCACHE) kcache_n = 0;              // sensor list changed a lot: start over
    c = kcache_n++; kcache[c].key = k;
    kcache[c].size = miss ? 0 : out.keyInfo.dataSize; kcache[c].type = miss ? 0 : out.keyInfo.dataType;
  }
  if (kcache[c].size == 0 || kcache[c].size > 32) return -1;
  memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
  in.key = k; in.keyInfo.dataSize = kcache[c].size; in.data8 = 5;
  if (smc_call(&in, &out) || out.result) return -1;
  *size = kcache[c].size; *type = kcache[c].type; memcpy(buf, out.bytes, *size);
  return 0;
}
static void key4(const char *s, char k[5]) { memcpy(k, "    ", 5); memcpy(k, s, strnlen(s, 4)); }
static double smc_temp(const char *key) {          // sp78, NAN if unreadable or implausible
  char k[5]; key4(key, k); unsigned char b[32]; UInt32 sz, ty;
  if (smc_read(k, b, &sz, &ty) || ty != k2u("sp78") || sz != 2) return NAN;
  double v = (signed char)b[0] + b[1] / 256.0;
  return v >= 0 && v <= 130 ? v : NAN;
}
static double smc_fpe2(const char *key) {
  char k[5]; key4(key, k); unsigned char b[32]; UInt32 sz, ty;
  if (smc_read(k, b, &sz, &ty) || ty != k2u("fpe2") || sz != 2) return NAN;
  return ((b[0] << 8) | b[1]) / 4.0;
}
static double smc_watts(const char *key) {         // sp96: int16 / 64 = W (PCPL = 65.00 W = TDP)
  char k[5]; key4(key, k); unsigned char b[32]; UInt32 sz, ty;
  if (smc_read(k, b, &sz, &ty) || ty != k2u("sp96") || sz != 2) return NAN;
  return (double)(int16_t)((b[0] << 8) | b[1]) / 64.0;
}
static int smc_int(const char *key) {             // ui8 / ui16, -1 if unreadable
  char k[5]; key4(key, k); unsigned char b[32]; UInt32 sz, ty;
  if (smc_read(k, b, &sz, &ty)) return -1;
  if (sz == 1) return b[0];
  if (sz == 2) return (b[0] << 8) | b[1];
  return -1;
}

// generic fixed point: spXY = int16 / 2^Y, fpXY = uint16 / 2^Y (X, Y hex digits), ui8/ui16, si8
static int hexd(char c) { return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1; }
static int num_type(UInt32 ty, UInt32 sz) {
  char t[5]; t[0] = (char)(ty >> 24); t[1] = (char)(ty >> 16); t[2] = (char)(ty >> 8); t[3] = (char)ty; t[4] = 0;
  if (sz == 2 && (t[0] == 's' || t[0] == 'f') && t[1] == 'p' && hexd(t[2]) >= 0 && hexd(t[3]) >= 0) return 1;
  if (!strcmp(t, "ui16") && sz == 2) return 1;
  if (sz == 1 && (!memcmp(t, "ui8", 3) || !memcmp(t, "si8", 3)) && (t[3] == ' ' || t[3] == 0)) return 1;
  return 0;
}
static double smc_num(const char *key) {
  char k[5]; key4(key, k); unsigned char b[32]; UInt32 sz, ty;
  if (smc_read(k, b, &sz, &ty) || !num_type(ty, sz)) return NAN;
  char t0 = (char)(ty >> 24), t3 = (char)ty;
  if (sz == 1) return t0 == 's' ? (double)(int8_t)b[0] : (double)b[0];
  unsigned v = (b[0] << 8) | b[1];
  if (t0 == 'u') return v;
  int fr = hexd(t3); if (fr < 0) return NAN;
  double sc = (double)(1u << fr);
  return t0 == 's' ? (double)(int16_t)v / sc : (double)v / sc;
}
// all keys by index (read commands 8 = key at index, 9 = key info); keeps T/P/V/I numbers + ALSL
static int next_ext; static char ext[MAX_EXT][5];
static int core_key(const char *k, const char sens[][5], int ns) {
  static const char *pk[] = { "PDTR", "PCPT", "PCTR", "PG0R", "PZ2G" };
  for (int i = 0; i < 5; i++) if (!strcmp(k, pk[i])) return 1;
  for (int i = 0; i < ns; i++) if (!strcmp(k, sens[i])) return 1;
  return 0;
}
static void smc_enum(const char sens[][5], int ns) {
  smc_data_t in, out; memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
  unsigned char b[32]; UInt32 sz, ty;
  if (smc_read("#KEY", b, &sz, &ty) || sz != 4) return;
  UInt32 n = ((UInt32)b[0] << 24) | ((UInt32)b[1] << 16) | ((UInt32)b[2] << 8) | b[3];
  next_ext = 0;
  for (UInt32 x = 0; x < n && x < 2000 && next_ext < MAX_EXT; x++) {
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.data8 = 8; in.data32 = x;
    if (smc_call(&in, &out) || out.result) continue;
    char k[5]; k[0] = (char)(out.key >> 24); k[1] = (char)(out.key >> 16); k[2] = (char)(out.key >> 8); k[3] = (char)out.key; k[4] = 0;
    int ok = 1; for (int i = 0; i < 4; i++) if (k[i] < 0x21 || k[i] > 0x7e || k[i] == ',') ok = 0;   // also no blanks: CSV header
    if (!ok) continue;
    int want = strchr("TPVI", k[0]) != NULL || !strcmp(k, "ALSL");
    if (!want || core_key(k, sens, ns) || !strcmp(k, "TH0O") || !strcmp(k, "TH1O")) continue;
    if (!strcmp(k, "PD2R") || !strcmp(k, "PD2S")) continue;           // = PDTR
    if (k[3] >= 'a' && k[3] <= 'z') {                                  // TC0p etc.: copy of TC0P
      char up[5]; memcpy(up, k, 5); up[3] = (char)(up[3] - 32);
      unsigned char ub[32]; UInt32 usz, uty;
      if (smc_read(up, ub, &usz, &uty) == 0 && num_type(uty, usz)) continue;
    }
    if (smc_read(k, b, &sz, &ty) || !num_type(ty, sz)) continue;
    snprintf(ext[next_ext++], 5, "%s", k);
  }
}

// --------------------------------------------------------------------------- IORegistry, host
static CFTypeRef dict_path(CFTypeRef d, const char *a, const char *b) {   // d[a][b] (b may be NULL)
  if (!d || CFGetTypeID(d) != CFDictionaryGetTypeID()) return NULL;
  CFStringRef ka = CFStringCreateWithCString(NULL, a, kCFStringEncodingUTF8);
  CFTypeRef v = CFDictionaryGetValue((CFDictionaryRef)d, ka); CFRelease(ka);
  if (!b || !v) return v;
  if (CFGetTypeID(v) != CFDictionaryGetTypeID()) return NULL;
  CFStringRef kb = CFStringCreateWithCString(NULL, b, kCFStringEncodingUTF8);
  CFTypeRef w = CFDictionaryGetValue((CFDictionaryRef)v, kb); CFRelease(kb);
  return w;
}
// sums of property[keys[i]] over every service of a class, one pass; NAN when none has it
static void ioreg_sums(const char *cls, const char *prop, const char *const keys[], int n, double out[]) {
  io_iterator_t it; io_object_t o; int found[8] = { 0 };
  for (int i = 0; i < n; i++) out[i] = 0;
  if (n > 8 || IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching(cls), &it) != kIOReturnSuccess) { for (int i = 0; i < n; i++) out[i] = NAN; return; }
  CFStringRef kp = CFStringCreateWithCString(NULL, prop, kCFStringEncodingUTF8);
  while ((o = IOIteratorNext(it))) {
    CFTypeRef p = IORegistryEntryCreateCFProperty(o, kp, kCFAllocatorDefault, 0);
    if (p) {
      for (int i = 0; i < n; i++) {
        CFTypeRef v = dict_path(p, keys[i], NULL); long long x;
        if (v && CFGetTypeID(v) == CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)v, kCFNumberLongLongType, &x)) { out[i] += (double)x; found[i] = 1; }
      }
      CFRelease(p);
    }
    IOObjectRelease(o);
  }
  CFRelease(kp); IOObjectRelease(it);
  for (int i = 0; i < n; i++) if (!found[i]) out[i] = NAN;
}
// sum of property[sub1][sub2] over every service of a class; NAN when none has it
static double ioreg_sum(const char *cls, const char *prop, const char *sub1, const char *sub2) {
  io_iterator_t it; io_object_t o; double sum = 0; int found = 0;
  if (IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching(cls), &it) != kIOReturnSuccess) return NAN;
  CFStringRef kp = CFStringCreateWithCString(NULL, prop, kCFStringEncodingUTF8);
  while ((o = IOIteratorNext(it))) {
    CFTypeRef p = IORegistryEntryCreateCFProperty(o, kp, kCFAllocatorDefault, 0);
    if (p) {
      CFTypeRef v = sub1 ? dict_path(p, sub1, sub2) : p;
      long long x;
      if (v && CFGetTypeID(v) == CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)v, kCFNumberLongLongType, &x)) { sum += (double)x; found = 1; }
      CFRelease(p);
    }
    IOObjectRelease(o);
  }
  CFRelease(kp); IOObjectRelease(it);
  return found ? sum : NAN;
}
static mach_port_t host_port(void) { static mach_port_t h; if (!h) h = mach_host_self(); return h; }
static double cpu_raw(void) {                      // 0..1 over all cores since the last call
  static unsigned long long lb, lt;
  natural_t n = 0; processor_info_array_t info = NULL; mach_msg_type_number_t cnt = 0;
  if (host_processor_info(host_port(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt) != KERN_SUCCESS || !info) return NAN;
  unsigned long long b = 0, t = 0;
  for (natural_t i = 0; i < n; i++) {
    const unsigned int *c = (const unsigned int *)&info[i * CPU_STATE_MAX];
    b += (unsigned long long)c[CPU_STATE_USER] + c[CPU_STATE_SYSTEM] + c[CPU_STATE_NICE];
    t += (unsigned long long)c[CPU_STATE_USER] + c[CPU_STATE_SYSTEM] + c[CPU_STATE_NICE] + c[CPU_STATE_IDLE];
  }
  vm_deallocate(mach_task_self(), (vm_address_t)info, cnt * sizeof(integer_t));
  double r = (lt && t > lt && b >= lb) ? (double)(b - lb) / (double)(t - lt) : NAN;
  lb = b; lt = t; return r;
}
static void vm_pages(double *pin, double *pout) {
  vm_statistics_data_t vs; mach_msg_type_number_t c = HOST_VM_INFO_COUNT;
  *pin = *pout = NAN;
  if (host_statistics(host_port(), HOST_VM_INFO, (host_info_t)&vs, &c) == KERN_SUCCESS) { *pin = vs.pageins; *pout = vs.pageouts; }
}
// network bytes/s over physical interfaces (en*): if_data counters are 32 bit on 10.9, so each
// interface keeps its last value and the delta is taken modulo 2^32 (wraps every ~40 s at GbE)
static void net_rates(double now, double *in, double *out) {
  static struct { char name[16]; uint32_t i, o; } last[8]; static int nlast; static double lt;
  struct ifaddrs *ia, *a; *in = *out = NAN;
  if (getifaddrs(&ia)) return;
  double di = 0, dn = 0; int have = lt > 0 && now > lt;
  for (a = ia; a; a = a->ifa_next) {
    if (!a->ifa_addr || a->ifa_addr->sa_family != AF_LINK || !a->ifa_data || strncmp(a->ifa_name, "en", 2)) continue;
    const struct if_data *d = (const struct if_data *)a->ifa_data;
    int j; for (j = 0; j < nlast; j++) if (!strcmp(last[j].name, a->ifa_name)) break;
    if (j == nlast) { if (nlast >= 8) continue; snprintf(last[nlast].name, sizeof last[0].name, "%s", a->ifa_name); last[nlast].i = d->ifi_ibytes; last[nlast].o = d->ifi_obytes; nlast++; continue; }
    di += (uint32_t)(d->ifi_ibytes - last[j].i); dn += (uint32_t)(d->ifi_obytes - last[j].o);
    last[j].i = d->ifi_ibytes; last[j].o = d->ifi_obytes;
  }
  freeifaddrs(ia);
  if (have) { *in = di / (now - lt); *out = dn / (now - lt); }
  lt = now;
}
// counters -> rates per second (NAN on the first call, after a reset or a wrap)
enum { C_DR, C_DW, C_DRO, C_DWO, C_PI, C_PO, C_PM4, C_UVD, C_N };
static double rate(int c, double v, double now) {
  static double lv[C_N], lt[C_N]; static int have[C_N];
  double r = NAN;
  if (!isnan(v) && have[c] && v >= lv[c] && now > lt[c]) r = (v - lv[c]) / (now - lt[c]);
  if (!isnan(v)) { lv[c] = v; lt[c] = now; have[c] = 1; }
  return r;
}

// drive temperature (SMART attribute 194) when sofa-fand does not deliver it (unloaded for a test).
// The SMART user client is exclusive: open, read, close; at most once per 60 s.
static double smart_temp(void) {
  static double last = NAN; static time_t at;
  time_t now = time(NULL);
  if (now - at < 60) return last;
  at = now - 50; last = NAN;                         // failed read: try again in ~10 s
  io_iterator_t it; io_object_t o; int done = 0;
  if (IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IOBlockStorageDevice"), &it)) return last;
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
            for (int i = 0; i < 30; i++) { unsigned char *a = b + 2 + i * 12; if (a[0] == 194) { if (a[5] > 5 && a[5] < 90) { last = a[5]; at = now; } break; } }
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
  return last;
}

// ------------------------------------------------------------------------- sofa-fand status
typedef struct {
  int ok; char mode[12], profile[12]; double shift, vol, cpu, gpu, hdd;
  int nsens; char sens[MAX_SENS][5];
} fand_t;
static int fand_status(fand_t *f) {
  memset(f, 0, sizeof *f); f->shift = f->vol = f->cpu = f->gpu = f->hdd = NAN;
  snprintf(f->mode, sizeof f->mode, "-"); snprintf(f->profile, sizeof f->profile, "-");
  int fd = socket(AF_UNIX, SOCK_STREAM, 0); if (fd < 0) return -1;
  struct timeval tv = { 1, 0 };
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv); setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
  int on = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
  struct sockaddr_un sa; memset(&sa, 0, sizeof sa); sa.sun_family = AF_UNIX; snprintf(sa.sun_path, sizeof sa.sun_path, "%s", CTL_SOCK);
  char buf[8192]; size_t n = 0;
  if (connect(fd, (struct sockaddr *)&sa, sizeof sa) || write(fd, "STATUS\n", 7) != 7) { close(fd); return -1; }
  for (;;) { ssize_t k = read(fd, buf + n, sizeof buf - 1 - n); if (k <= 0) break; n += (size_t)k; if (n >= sizeof buf - 1) break; }
  close(fd); buf[n] = 0;
  if (!strstr(buf, "\n.\n")) return -1;                 // incomplete answer
  for (char *l = strtok(buf, "\n"); l; l = strtok(NULL, "\n")) {
    char a[16], b[16]; double x, y;
    if (sscanf(l, "mode %11s", a) == 1) snprintf(f->mode, sizeof f->mode, "%s", a);
    else if (sscanf(l, "profile %11s shift %lf", a, &x) == 2) {
      snprintf(f->profile, sizeof f->profile, "%s", a); f->shift = x;
      const char *v = strstr(l, " vol "); if (v && sscanf(v, " vol %lf", &y) == 1 && y >= 0) f->vol = y;
    }
    else if (sscanf(l, "load cpu %lf gpu %lf", &x, &y) == 2) { f->cpu = x; f->gpu = y; }
    else if (sscanf(l, "temp %4s %15s", a, b) == 2) {
      if (!strcmp(a, "HDD")) f->hdd = strcmp(b, "n/a") ? atof(b) : NAN;
      else if (f->nsens < MAX_SENS) snprintf(f->sens[f->nsens++], 5, "%s", a);
    }
  }
  f->ok = 1; return 0;
}

// ------------------------------------------------------------------------------------ buffer
static char *buf; static size_t blen;
static char outdir[512];
static char cur_day[16];
static char header[8192], last_header[8192];
static volatile sig_atomic_t stop, flush_now;
static void on_sig(int s) { if (s == SIGHUP) flush_now = 1; else stop = 1; }

static void bappend(const char *s) {
  size_t n = strlen(s);
  if (blen + n + 1 > BUF_MAX) return;                    // flush() runs before this can happen
  memcpy(buf + blen, s, n); blen += n; buf[blen] = 0;
}
static void prune(void) {                                // drop day files older than KEEP_DAYS
  DIR *d = opendir(outdir); if (!d) return;
  time_t lim = time(NULL) - KEEP_DAYS * 86400; struct dirent *e;
  while ((e = readdir(d))) {
    int y, m, dd; char tail[8]; const char *nm = e->d_name;
    if (strlen(nm) != 14) continue;
    int digits = 1; for (int i = 0; i < 10; i++) if (i != 4 && i != 7 && (nm[i] < '0' || nm[i] > '9')) digits = 0;
    if (!digits || nm[4] != '-' || nm[7] != '-') continue;
    if (sscanf(e->d_name, "%4d-%2d-%2d.%7s", &y, &m, &dd, tail) != 4 || strcmp(tail, "csv")) continue;
    struct tm t; memset(&t, 0, sizeof t); t.tm_year = y - 1900; t.tm_mon = m - 1; t.tm_mday = dd; t.tm_hour = 12;
    if (mktime(&t) < lim) { char p[800]; snprintf(p, sizeof p, "%s/%s", outdir, e->d_name); unlink(p); }
  }
  closedir(d);
}
static int flush_buf(void) {
  if (!blen) return 0;
  char p[600]; snprintf(p, sizeof p, "%s/%s.csv", outdir, cur_day);
  int fd = open(p, O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (fd < 0) { fprintf(stderr, "sofa-fanlearn: open %s: %s\n", p, strerror(errno)); return -1; }
  off_t start = lseek(fd, 0, SEEK_END);
  size_t o = 0;
  while (o < blen) {
    ssize_t w = write(fd, buf + o, blen - o);
    if (w < 0 && errno == EINTR) continue;
    if (w <= 0) break;
    o += (size_t)w;
  }
  if (o < blen) {                                      // keep the buffer, cut the torn tail off
    if (start >= 0 && ftruncate(fd, start)) {}
    close(fd); fprintf(stderr, "sofa-fanlearn: short write %s: %s\n", p, strerror(errno)); return -1;
  }
  close(fd);
  blen = 0; buf[0] = 0;
  return 0;
}

// ------------------------------------------------------------------------------------ sample
static int nfans = -1;
static int sample(char *line, size_t cap, int *busy) {
  fand_t f; fand_status(&f);
  static fand_t last;                                   // keep the last known sensor list
  if (f.ok) last = f; else { int ns = last.nsens; memcpy(f.sens, last.sens, sizeof f.sens); f.nsens = ns; }
  if (nfans < 0) { int v = smc_int("FNum"); if (v >= 0) nfans = v > MAX_FANS ? MAX_FANS : v; }   // retried until readable
  int nf = nfans < 0 ? 0 : nfans;
  static const char *pk[] = { "PDTR", "PCPT", "PCTR", "PG0R", "PZ2G" };
  // enumeration once the controller's sensor list is known (or without it after 3 tries)
  static int enum_done, tries;
  if (!enum_done && (f.nsens > 0 || ++tries > 3)) { smc_enum(f.sens, f.nsens); enum_done = 1; }
  static unsigned long seq; int do_ext = (seq++ % EXT_EVERY) == 0;
  double now = (double)time(NULL);
  // header (changes only with the sensor list; then a new header line is written)
  size_t h = 0;
  #define HDR(...) do { int _n = snprintf(header + h, h < sizeof header ? sizeof header - h : 0, __VA_ARGS__); if (_n > 0) h += (size_t)_n; } while (0)
  HDR("#epoch,mode,profile,shift,vol,cpu,gpu,fs,cpu_raw,gpu_pm4_s,gpu_uvd_s,disp_pwr,bright,disk_rB_s,disk_wB_s,disk_rops_s,disk_wops_s,net_inB_s,net_outB_s,pagein_s,pageout_s");
  for (int n = 0; n < nf; n++) HDR(",F%dAc,F%dTg", n, n);
  for (int i = 0; i < 5; i++) HDR(",%s", pk[i]);
  for (int i = 0; i < f.nsens; i++) HDR(",%s", f.sens[i]);
  HDR(",HDD");
  for (int i = 0; i < next_ext; i++) if (!core_key(ext[i], f.sens, f.nsens)) HDR(",%s", ext[i]);   // no duplicates
  HDR("\n");
  #undef HDR
  if (h >= sizeof header) return -1;

  size_t o = 0; int anyfan = 0;
  #define OUT(...) do { int _n = snprintf(line + o, o < cap ? cap - o : 0, __VA_ARGS__); if (_n > 0) o += (size_t)_n; } while (0)
  #define NUM(fmt, v) do { double _v = (v); if (isnan(_v)) OUT(","); else OUT("," fmt, _v); } while (0)   // v once
  OUT("%ld,%s,%s", (long)time(NULL), f.mode, f.profile);
  NUM("%.1f", f.shift); NUM("%.2f", f.vol); NUM("%.2f", f.cpu); NUM("%.2f", f.gpu);
  int fs = smc_int("FS! "); OUT(",%d", fs);
  double cr = cpu_raw(); NUM("%.3f", cr);
  static const char *const gk[] = { "HWChannel PM4 | Commands Completed", "HWChannel UVD | Commands Completed" };
  static const char *const dk[] = { "Bytes (Read)", "Bytes (Write)", "Operations (Read)", "Operations (Write)" };
  double gv[2], dv[4]; ioreg_sums("IOAccelerator", "PerformanceStatistics", gk, 2, gv); ioreg_sums("IOBlockStorageDriver", "Statistics", dk, 4, dv);
  NUM("%.0f", rate(C_PM4, gv[0], now));
  NUM("%.0f", rate(C_UVD, gv[1], now));
  NUM("%.0f", ioreg_sum("IODisplayWrangler", "IOPowerManagement", "CurrentPowerState", NULL));
  NUM("%.0f", ioreg_sum("AppleBacklightDisplay", "IODisplayParameters", "brightness", "value"));
  NUM("%.0f", rate(C_DR, dv[0], now)); NUM("%.0f", rate(C_DW, dv[1], now));
  NUM("%.2f", rate(C_DRO, dv[2], now)); NUM("%.2f", rate(C_DWO, dv[3], now));
  double ni, no, pi, po; net_rates(now, &ni, &no); vm_pages(&pi, &po);
  NUM("%.0f", ni); NUM("%.0f", no);
  NUM("%.2f", rate(C_PI, pi, now)); NUM("%.2f", rate(C_PO, po, now));
  for (int n = 0; n < nf; n++) {
    char k[8]; snprintf(k, sizeof k, "F%dAc", n); double ac = smc_fpe2(k);
    snprintf(k, sizeof k, "F%dTg", n); double tg = smc_fpe2(k);
    NUM("%.0f", ac); NUM("%.0f", tg); if (ac > 100) anyfan = 1;
  }
  for (int i = 0; i < 5; i++) NUM("%.2f", smc_watts(pk[i]));
  for (int i = 0; i < f.nsens; i++) NUM("%.2f", smc_temp(f.sens[i]));
  NUM("%.0f", isnan(f.hdd) ? smart_temp() : f.hdd);   // own SMART read only while sofa-fand has none
  for (int i = 0; i < next_ext; i++) {                 // same filter as the header
    if (core_key(ext[i], f.sens, f.nsens)) continue;
    if (do_ext) NUM("%.3f", smc_num(ext[i])); else OUT(",");
  }
  OUT("\n");
  #undef NUM
  #undef OUT
  *busy = anyfan || (!isnan(f.cpu) && f.cpu > 0.10) || (!isnan(f.gpu) && f.gpu > 0.10);
  return o < cap ? 0 : -1;
}

static void day_of(time_t t, char *d, size_t cap) { struct tm tm; localtime_r(&t, &tm); strftime(d, cap, "%Y-%m-%d", &tm); }

int main(int argc, char **argv) {
  if (argc < 2 || (strcmp(argv[1], "log") && strcmp(argv[1], "once"))) {
    fprintf(stderr, "usage: sofa-fanlearn log [-o dir] [-f flush_s] | once\n"); return 2;
  }
  if (smc_open()) { fprintf(stderr, "sofa-fanlearn: AppleSMC not available\n"); return 1; }
  static char line[16384]; int busy = 0;
  if (!strcmp(argv[1], "once")) {
    if (sample(line, sizeof line, &busy)) return 1;
    fputs(header, stdout); fputs(line, stdout); return 0;
  }
  int flush_s = 4 * 3600;
  const char *home = getenv("HOME");
  snprintf(outdir, sizeof outdir, "%s/Library/Logs/sofa-fanlearn", home ? home : "/tmp");
  for (int i = 2; i < argc; i++) {
    if (!strcmp(argv[i], "-o") && i + 1 < argc) snprintf(outdir, sizeof outdir, "%s", argv[++i]);
    else if (!strcmp(argv[i], "-f") && i + 1 < argc) { flush_s = atoi(argv[++i]); if (flush_s < 10) flush_s = 10; }
    else { fprintf(stderr, "sofa-fanlearn: unknown argument %s\n", argv[i]); return 2; }
  }
  if (mkdir(outdir, 0755) && errno != EEXIST) { fprintf(stderr, "sofa-fanlearn: mkdir %s: %s\n", outdir, strerror(errno)); return 1; }
  buf = malloc(BUF_MAX); if (!buf) return 1; buf[0] = 0;
  struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = on_sig;   // no SA_RESTART: sleep returns
  sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL); sigaction(SIGHUP, &sa, NULL);
  sigset_t blk, orig; sigemptyset(&blk); sigaddset(&blk, SIGTERM); sigaddset(&blk, SIGINT); sigaddset(&blk, SIGHUP);
  sigprocmask(SIG_BLOCK, &blk, &orig);
  prune();
  time_t last_flush = time(NULL);
  day_of(last_flush, cur_day, sizeof cur_day);
  fprintf(stderr, "sofa-fanlearn: logging to %s, flush every %d s\n", outdir, flush_s);
  while (!stop) {
    time_t now = time(NULL); char d[16]; day_of(now, d, sizeof d);
    if (strcmp(d, cur_day) && flush_buf() == 0) { snprintf(cur_day, sizeof cur_day, "%s", d); last_header[0] = 0; prune(); }
    if (sample(line, sizeof line, &busy) == 0) {
      if (blen + strlen(header) + strlen(line) + 1 > BUF_MAX) flush_buf();
      if (strcmp(header, last_header)) { bappend(header); snprintf(last_header, sizeof last_header, "%s", header); }
      bappend(line);
    }
    if (flush_now || now - last_flush >= flush_s) { flush_now = 0; flush_buf(); last_flush = now; }
    // signals are blocked except inside pselect: a SIGTERM can never slip in before the wait
    struct timespec ts = { busy ? DT_BUSY : DT_CALM, 0 };
    if (!stop && !flush_now) pselect(0, NULL, NULL, NULL, &ts, &orig);
  }
  flush_buf();
  return 0;
}
