// SMC transport: key read/write, temperatures, FS! (forced-mode mask) and F<n>Tg (targets).
#include "fand.h"
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <string.h>
#include <unistd.h>

typedef struct { char major, minor, build, reserved[1]; UInt16 release; } smc_vers_t;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } smc_plimit_t;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } smc_keyinfo_t;
typedef struct {
  UInt32 key; smc_vers_t vers; smc_plimit_t pLimitData; smc_keyinfo_t keyInfo;
  char result; char status; char data8; UInt32 data32; unsigned char bytes[32];
} smc_data_t;
enum { SMC_READ_BYTES = 5, SMC_WRITE_BYTES = 6, SMC_READ_INDEX = 8, SMC_READ_KEYINFO = 9 };

static io_connect_t smc;   // per process (Mach ports do not survive fork)
int dry;
static int dry_fs;         // what FS! would be in dry mode

UInt32 k2u(const char *s) { return ((UInt32)(unsigned char)s[0]<<24)|((UInt32)(unsigned char)s[1]<<16)|((UInt32)(unsigned char)s[2]<<8)|(UInt32)(unsigned char)s[3]; }
static void u2k(UInt32 v, char k[5]) { k[0] = (char)(v >> 24); k[1] = (char)(v >> 16); k[2] = (char)(v >> 8); k[3] = (char)v; k[4] = 0; }
int key_ok(const char *k) { size_t n = strlen(k); if (n < 1 || n > 4) return 0; for (size_t i = 0; i < n; i++) if (k[i] < 0x20 || k[i] > 0x7e) return 0; return 1; }

double now_s(void) {
  static mach_timebase_info_data_t tb;
  if (!tb.denom) mach_timebase_info(&tb);
  return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

int smc_open(void) {
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

// Key info (size, type) never changes: cache it, so a read is one SMC transaction, not two.
#define KCACHE 64
static struct { UInt32 key, size, type; } kcache[KCACHE];
static int kcache_n;
static pthread_mutex_t kcache_mx = PTHREAD_MUTEX_INITIALIZER;
static int read_ex(const char *key, unsigned char *buf, UInt32 *size, UInt32 *type, int cache) {
  smc_data_t in, out; memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
  char k4[5] = "    "; memcpy(k4, key, strnlen(key, 4));
  in.key = k2u(k4);
  int hit = -1;
  pthread_mutex_lock(&kcache_mx);
  for (int i = 0; i < kcache_n; i++) if (kcache[i].key == in.key) { hit = i; *size = kcache[i].size; *type = kcache[i].type; break; }
  pthread_mutex_unlock(&kcache_mx);
  if (hit < 0) {
    in.data8 = SMC_READ_KEYINFO;
    if (smc_call(&in, &out) || out.result) return -1;
    *size = out.keyInfo.dataSize; *type = out.keyInfo.dataType;
    if (*size == 0 || *size > 32) return -1;
    if (cache) {
      pthread_mutex_lock(&kcache_mx);
      int slot = -1;
      for (int i = 0; i < kcache_n; i++) if (kcache[i].key == 0) { slot = i; break; }   // reuse an invalidated slot
      if (slot < 0 && kcache_n < KCACHE) slot = kcache_n++;
      if (slot >= 0) { kcache[slot].key = in.key; kcache[slot].size = *size; kcache[slot].type = *type; }
      pthread_mutex_unlock(&kcache_mx);
    }
  }
  in.keyInfo.dataSize = *size; in.data8 = SMC_READ_BYTES;
  memset(&out, 0, sizeof out);
  if (smc_call(&in, &out) || out.result) {
    if (hit >= 0) { pthread_mutex_lock(&kcache_mx); kcache[hit].key = 0; pthread_mutex_unlock(&kcache_mx); }   // re-query next time
    return -1;
  }
  memcpy(buf, out.bytes, *size);
  return 0;
}
int smc_read(const char *key, unsigned char *buf, UInt32 *size, UInt32 *type) { return read_ex(key, buf, size, type, 1); }

static int smc_write(const char *key, const unsigned char *buf, UInt32 size) {
  smc_data_t in, out; memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
  char k4[5] = "    "; memcpy(k4, key, strnlen(key, 4));
  in.key = k2u(k4); in.data8 = SMC_WRITE_BYTES; in.keyInfo.dataSize = size;
  memcpy(in.bytes, buf, size);
  if (smc_call(&in, &out) || out.result) return -1;
  return 0;
}

int smc_key_count(void) {
  unsigned char b[32]; UInt32 sz, ty;
  if (read_ex("#KEY", b, &sz, &ty, 0) || sz != 4) return -1;
  return (int)(((UInt32)b[0] << 24) | ((UInt32)b[1] << 16) | ((UInt32)b[2] << 8) | b[3]);
}

int smc_key_at(int index, char key[5]) {
  smc_data_t in, out; memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
  in.data8 = SMC_READ_INDEX; in.data32 = (UInt32)index;
  if (smc_call(&in, &out) || out.result) return -1;
  u2k(out.key, key);
  return 0;
}

// any numeric SMC value: sp<i><f> / fp<i><f> fixed point (f fraction bits, hex digit), ui8/16/32,
// flt (little endian) - the power keys differ in type between models
int smc_num(const char *key, double *v) {
  unsigned char b[32]; UInt32 sz, ty;
  if (read_ex(key, b, &sz, &ty, 1)) return -1;
  char t[5]; u2k(ty, t);
  if ((t[0] == 's' || t[0] == 'f') && t[1] == 'p' && sz == 2) {
    int f = t[3] >= '0' && t[3] <= '9' ? t[3] - '0' : t[3] >= 'a' && t[3] <= 'f' ? t[3] - 'a' + 10 : -1;
    if (f < 0) return -1;
    unsigned raw = ((unsigned)b[0] << 8) | b[1];
    *v = (t[0] == 's' ? (double)(int16_t)raw : (double)raw) / (double)(1 << f);
    return 0;
  }
  if (!strcmp(t, "ui8 ") && sz == 1) { *v = b[0]; return 0; }
  if (!strcmp(t, "ui16") && sz == 2) { *v = (b[0] << 8) | b[1]; return 0; }
  if (!strcmp(t, "ui32") && sz == 4) { *v = (double)(((UInt32)b[0] << 24) | ((UInt32)b[1] << 16) | ((UInt32)b[2] << 8) | b[3]); return 0; }
  if (!strcmp(t, "flt ") && sz == 4) { float x; memcpy(&x, b, 4); *v = x; return 0; }
  return -1;
}

int smc_sp78(const char *key, double *v) {
  unsigned char b[32]; UInt32 sz, ty;
  if (read_ex(key, b, &sz, &ty, 0) || ty != k2u("sp78") || sz != 2) return -1;
  *v = (signed char)b[0] + b[1] / 256.0;
  return 0;
}

// sp78 temperature, plausible range only; one retry for a transient SMC hiccup
int smc_temp(const char *key, double *t) {
  for (int a = 0; a < 2; a++) {
    unsigned char b[32]; UInt32 sz, ty;
    if (smc_read(key, b, &sz, &ty) == 0 && ty == k2u("sp78") && sz == 2) {
      double v = (signed char)b[0] + b[1] / 256.0;
      if (v >= 5 && v <= 125) { *t = v; return 0; }
    }
    usleep(20000);
  }
  return -1;
}

int smc_fpe2(const char *key, double *r) {
  unsigned char b[32]; UInt32 sz, ty;
  if (smc_read(key, b, &sz, &ty) || ty != k2u("fpe2") || sz != 2) return -1;
  *r = ((b[0] << 8) | b[1]) / 4.0; return 0;
}

int fs_get(void) {
  if (dry) return dry_fs;
  unsigned char b[32]; UInt32 sz, ty;
  if (smc_read("FS! ", b, &sz, &ty) || sz != 2) return -1;
  return (b[0] << 8) | b[1];
}

int fs_set(int mask) {
  if (dry) { dry_fs = mask; return 0; }
  unsigned char b[2] = { (unsigned char)((mask >> 8) & 0xff), (unsigned char)(mask & 0xff) };
  return smc_write("FS! ", b, 2);
}

int tg_set(int fan, int rpm) {
  if (fan < 0 || fan >= MAX_FANS || rpm < 0 || rpm > 7000) return -1;
  if (dry) return 0;
  char k[5]; snprintf(k, sizeof k, "F%dTg", fan);
  unsigned v = (unsigned)rpm << 2;                                   // fpe2: 14.2 fixed point
  unsigned char b[2] = { (unsigned char)((v >> 8) & 0xff), (unsigned char)(v & 0xff) };
  return smc_write(k, b, 2);
}

// Back to SMC control, verified. Used on every exit path. If FS! cannot be cleared, the SMC
// still holds our forced speeds: then force every fan to its maximum instead, so a stuck forced
// mode is a loud one, never a quiet one.
static int fan_max_rpm[MAX_FANS];   // from the machine (SMC F<n>Mx), set before any forcing
static int nfan_max;
static int tg_sent[MAX_FANS], fs_sent = -1;   // last values written (-1 = unknown)
void smc_set_fan_max(int fan, int rpm) { if (fan >= 0 && fan < MAX_FANS) { fan_max_rpm[fan] = rpm; if (fan >= nfan_max) nfan_max = fan + 1; } }
void smc_forget_writes(void) { fs_sent = -1; for (int n = 0; n < MAX_FANS; n++) tg_sent[n] = -1; }
int smc_auto(void) {
  smc_forget_writes();
  for (int i = 0; i < 3; i++) { if (fs_set(0) == 0 && fs_get() == 0) return 0; usleep(50000); }
  int mask = 0;
  for (int n = 0; n < nfan_max; n++) if (fan_max_rpm[n] > 0) { tg_set(n, fan_max_rpm[n]); mask |= 1 << n; }
  fs_set(mask);
  return -1;
}

// cached writes: only changes reach the SMC; on full cycles everything is written and verified
int put_tg(int n, int rpm, int full) {
  if (!full && tg_sent[n] == rpm) return 0;
  if (tg_set(n, rpm)) { tg_sent[n] = -1; return -1; }
  tg_sent[n] = rpm; return 0;
}
int put_fs(int mask, int full) {
  // FS! is read back every step (one transaction): if anything outside reset it (SMC reset, a
  // tool, sleep without notice), every target is written again at once, not after FULL_EVERY
  if (!full && fs_sent == mask) {
    int now_fs = fs_get();
    if (now_fs == mask) return 0;
    smc_forget_writes();
    return -2;                       // caller writes the targets again and then FS!
  }
  if (fs_set(mask) || fs_get() != mask) { fs_sent = -1; return -1; }
  fs_sent = mask; return 0;
}
