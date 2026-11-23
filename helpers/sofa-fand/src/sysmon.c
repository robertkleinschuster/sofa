// Helper threads around the control loop: SMART drive temperature, CPU/GPU load (feed-forward),
// system sleep/wake. Each can block or fail on its own; the control loop only takes their last
// values (and treats a stale drive reading as an unreadable sensor).
#include "fand.h"
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/ata/ATASMARTLib.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOMessage.h>
#include <mach/mach.h>
#include <math.h>
#include <string.h>
#include <unistd.h>

// ================================================================ SMART drive temperature
// The SMART user client is exclusive (smartctl fails while anyone holds it), so it is opened,
// read and closed every time.
static pthread_mutex_t hdd_mx = PTHREAD_MUTEX_INITIALIZER;
static double hdd_temp = -1, hdd_when = -1;

static int smart_read_once(void) {
  io_iterator_t it; io_object_t o; int r = -1, done = 0;
  if (IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IOBlockStorageDevice"), &it) != kIOReturnSuccess) return -1;
  while ((o = IOIteratorNext(it))) {
    CFTypeRef cap = IORegistryEntrySearchCFProperty(o, kIOServicePlane, CFSTR("SMART Capable"), kCFAllocatorDefault, 0);
    if (cap && !done) {
      IOCFPlugInInterface **pi = NULL; SInt32 score; IOATASMARTInterface **si = NULL;
      if (IOCreatePlugInInterfaceForService(o, kIOATASMARTUserClientTypeID, kIOCFPlugInInterfaceID, &pi, &score) == kIOReturnSuccess && pi) {
        if ((*pi)->QueryInterface(pi, CFUUIDGetUUIDBytes(kIOATASMARTInterfaceID), (LPVOID *)&si) == S_OK && si) {
          ATASMARTData d; memset(&d, 0, sizeof d);
          if ((*si)->SMARTReadData(si, &d) == kIOReturnSuccess) {
            const unsigned char *b = (const unsigned char *)&d;
            for (int i = 0; i < 30; i++) {
              const unsigned char *a = b + 2 + i * 12;
              if (a[0] == 194) { r = a[5]; break; }               // raw value, low byte = deg C
            }
          }
          (*si)->Release(si);
        }
        IODestroyPlugInInterface(pi);
        done = 1;                                                 // first SMART drive only (disk0)
      }
    }
    if (cap) CFRelease(cap);
    IOObjectRelease(o);
  }
  IOObjectRelease(it);
  return r;
}

void *smart_thread(void *arg) {
  (void)arg;
  for (;;) {
    int t = smart_read_once();
    if (t < 0) { sleep(2); t = smart_read_once(); }          // smartctl may hold the client a moment
    if (t > 5 && t < 100) { pthread_mutex_lock(&hdd_mx); hdd_temp = t; hdd_when = now_s(); pthread_mutex_unlock(&hdd_mx); }
    int iv = cfg.hdd_interval;                                // an int: a reload's new value is taken whole
    sleep((unsigned)(iv >= 5 ? iv : 30));
  }
  return NULL;
}

int hdd_reading(double now, double stale, double *t) {
  pthread_mutex_lock(&hdd_mx);
  int ok = hdd_when > 0 && now - hdd_when <= stale; *t = hdd_temp;
  pthread_mutex_unlock(&hdd_mx);
  return ok;
}
int hdd_never_read(void) { pthread_mutex_lock(&hdd_mx); int r = hdd_when < 0; pthread_mutex_unlock(&hdd_mx); return r; }
double hdd_read_at(void) { pthread_mutex_lock(&hdd_mx); double r = hdd_when; pthread_mutex_unlock(&hdd_mx); return r; }

// ======================================================================= load (feed-forward)
static double cpu_load_raw(void) {                 // 0..1 over all cores since last call, NAN on error
  static unsigned long long lb, lt;
  natural_t n = 0; processor_info_array_t info = NULL; mach_msg_type_number_t cnt = 0;
  if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt) != KERN_SUCCESS || !info) return NAN;
  unsigned long long b = 0, t = 0;
  for (natural_t i = 0; i < n; i++) {
    const unsigned int *s = (const unsigned int *)&info[i * CPU_STATE_MAX];
    b += (unsigned long long)s[CPU_STATE_USER] + s[CPU_STATE_SYSTEM] + s[CPU_STATE_NICE];
    t += (unsigned long long)s[CPU_STATE_USER] + s[CPU_STATE_SYSTEM] + s[CPU_STATE_NICE] + s[CPU_STATE_IDLE];
  }
  vm_deallocate(mach_task_self(), (vm_address_t)info, cnt * sizeof(integer_t));
  double r = (lt && t > lt && b >= lb) ? (double)(b - lb) / (double)(t - lt) : NAN;
  lb = b; lt = t;
  return r;
}

static double gpu_load_raw(double full) {          // PM4 command rate / full, clamped 0..1
  static long long last = -1; static double last_t;
  io_iterator_t it; io_object_t o; long long v = -1;
  if (IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IOAccelerator"), &it) != kIOReturnSuccess) return NAN;
  while ((o = IOIteratorNext(it))) {
    CFTypeRef ps = IORegistryEntryCreateCFProperty(o, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
    if (ps && CFGetTypeID(ps) == CFDictionaryGetTypeID()) {
      CFTypeRef nr = CFDictionaryGetValue((CFDictionaryRef)ps, CFSTR("HWChannel PM4 | Commands Completed"));
      if (nr && CFGetTypeID(nr) == CFNumberGetTypeID() && v < 0) CFNumberGetValue((CFNumberRef)nr, kCFNumberLongLongType, &v);
    }
    if (ps) CFRelease(ps);
    IOObjectRelease(o);
  }
  IOObjectRelease(it);
  double t = now_s(), r = NAN;
  if (v >= 0 && last >= 0 && v >= last && t > last_t && full >= 1) { r = (double)(v - last) / (t - last_t) / full; if (r > 1) r = 1; }
  last = v; last_t = t;
  return r;
}

// The samplers allocate CF objects and talk to the GPU driver: own thread; the control loop only
// takes the last values (ignored when older than 10 s).
static pthread_mutex_t load_mx = PTHREAD_MUTEX_INITIALIZER;
static double load_cpu = NAN, load_gpu = NAN, load_when = -1, gpu_full_now = 3000;
void *load_thread(void *arg) {
  (void)arg;
  cpu_load_raw(); gpu_load_raw(gpu_full_now);
  for (;;) {
    sleep(5);
    pthread_mutex_lock(&load_mx); double full = gpu_full_now; pthread_mutex_unlock(&load_mx);
    double c = cpu_load_raw(), g = gpu_load_raw(full);
    pthread_mutex_lock(&load_mx); load_cpu = c; load_gpu = g; load_when = now_s(); pthread_mutex_unlock(&load_mx);
  }
  return NULL;
}
int load_now(double now, double *c, double *g) {
  pthread_mutex_lock(&load_mx);
  int ok = now - load_when < 10; *c = ok ? load_cpu : NAN; *g = ok ? load_gpu : NAN;
  gpu_full_now = cfg.gpu_full;                  // taken from the controller's configuration (reload)
  pthread_mutex_unlock(&load_mx);
  return ok;
}

// ============================================================================ sleep / wake
// Before the system sleeps the SMC gets the fans back (FS! = 0) and the controller pauses; after
// the wake it takes over again only with fresh sensor values. A hang during sleep/wake therefore
// leaves the fans under SMC control, never forced.
static io_connect_t pm_root;
volatile int pm_failed;
void power_sleep(void) {
  pthread_mutex_lock(&ctl_mx);
  sleeping = 1; shm->sleeping = 1;
  int failed = smc_auto(); shm->forced = 0;
  pthread_mutex_unlock(&ctl_mx);
  logf_("system sleep: FS!=0%s", failed ? " FAILED" : "");
}
void power_wake(void) {
  pthread_mutex_lock(&ctl_mx);
  woke_at = now_s(); sleeping = 0; shm->sleeping = 0;
  control_after_wake();             // next step reads every sensor and writes everything again
  poke(wake_pipe[1]);
  smc_forget_writes();
  pthread_mutex_unlock(&ctl_mx);
  logf_("system woke: waiting for fresh sensors");
}
static void power_cb(void *ref, io_service_t svc, natural_t type, void *arg) {
  (void)ref; (void)svc;
  switch (type) {
    case kIOMessageCanSystemSleep: IOAllowPowerChange(pm_root, (long)arg); break;
    case kIOMessageSystemWillSleep: power_sleep(); IOAllowPowerChange(pm_root, (long)arg); break;
    case kIOMessageSystemWillPowerOn: break;
    case kIOMessageSystemHasPoweredOn: power_wake(); break;
    default: break;
  }
}
void *power_thread(void *arg) {
  (void)arg;
  IONotificationPortRef port = NULL; io_object_t notifier;
  pm_root = IORegisterForSystemPower(NULL, &port, power_cb, &notifier);
  if (!pm_root || !port) { pm_failed = 1; logf_("IORegisterForSystemPower failed - sleep cannot be handled, fans stay under SMC control"); return NULL; }
  CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(port), kCFRunLoopCommonModes);
  CFRunLoopRun();
  return NULL;
}
