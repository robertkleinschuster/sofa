// smcfan – minimales SMC-Werkzeug für Lüfter/Temperaturen (iMac12,2, macOS 10.9)
//   smcfan status              Lüfter (Ist/Min/Max/Ziel) + Temperaturen
//   smcfan read KEY            einzelnen Schlüssel lesen (Hex + Typ)
//   smcfan setmin N RPM        Minimum von Lüfter N setzen (nur F<N>Mn, kein Zwangsmodus; root)
// Schreibt ausschließlich F<n>Mn. Der SMC regelt oberhalb des Minimums weiter selbst.
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_KEYINFO 9

typedef struct { char major, minor, build, reserved[1]; UInt16 release; } vers_t;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } plimit_t;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } keyinfo_t;
typedef struct {
  UInt32 key; vers_t vers; plimit_t pLimitData; keyinfo_t keyInfo;
  char result; char status; char data8; UInt32 data32; unsigned char bytes[32];
} SMCKeyData_t;

static io_connect_t conn;

static UInt32 k2u(const char *s) { return ((UInt32)s[0]<<24)|((UInt32)s[1]<<16)|((UInt32)s[2]<<8)|(UInt32)s[3]; }
static void u2k(UInt32 v, char *s) { s[0]=v>>24; s[1]=v>>16; s[2]=v>>8; s[3]=v; s[4]=0; }

static int call(SMCKeyData_t *in, SMCKeyData_t *out) {
  size_t sz = sizeof(SMCKeyData_t);
  return IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, sizeof(*in), out, &sz) == kIOReturnSuccess ? 0 : -1;
}

static int smc_read(const char *key, unsigned char *buf, UInt32 *size, char *type) {
  SMCKeyData_t in, out; memset(&in,0,sizeof in); memset(&out,0,sizeof out);
  in.key = k2u(key); in.data8 = SMC_CMD_READ_KEYINFO;
  if (call(&in,&out) || out.result) return -1;
  *size = out.keyInfo.dataSize; u2k(out.keyInfo.dataType, type);
  in.keyInfo.dataSize = *size; in.data8 = SMC_CMD_READ_BYTES;
  memset(&out,0,sizeof out);
  if (call(&in,&out) || out.result) return -1;
  memcpy(buf, out.bytes, *size > 32 ? 32 : *size);
  return 0;
}

static int smc_write(const char *key, const unsigned char *buf, UInt32 size) {
  SMCKeyData_t in, out; memset(&in,0,sizeof in); memset(&out,0,sizeof out);
  in.key = k2u(key); in.data8 = SMC_CMD_WRITE_BYTES; in.keyInfo.dataSize = size;
  memcpy(in.bytes, buf, size);
  if (call(&in,&out)) return -1;
  return out.result ? -(int)out.result - 100 : 0;
}

static double fpe2(const unsigned char *b) { return ((b[0]<<8)|b[1]) / 4.0; }
static double sp78(const unsigned char *b) { return (signed char)b[0] + b[1]/256.0; }

static double readnum(const char *key, int *ok) {
  unsigned char b[32]; UInt32 sz; char t[5];
  *ok = 0;
  if (smc_read(key,b,&sz,t)) return 0;
  *ok = 1;
  if (!strcmp(t,"fpe2")) return fpe2(b);
  if (!strcmp(t,"sp78")) return sp78(b);
  if (!strcmp(t,"ui8 ")) return b[0];
  if (!strcmp(t,"ui16")) return (b[0]<<8)|b[1];
  *ok = 0; return 0;
}

static void status(void) {
  int ok; int n = (int)readnum("FNum",&ok);
  printf("Lüfter: %d\n", n);
  for (int i=0;i<n;i++) {
    char k[5]; unsigned char b[32]; UInt32 sz; char t[5]; char name[17]="";
    snprintf(k,5,"F%dID",i);
    if (!smc_read(k,b,&sz,t) && sz >= 16) { memcpy(name,b+4,12); name[12]=0; }
    double ac,mn,mx,tg;
    snprintf(k,5,"F%dAc",i); ac=readnum(k,&ok);
    snprintf(k,5,"F%dMn",i); mn=readnum(k,&ok);
    snprintf(k,5,"F%dMx",i); mx=readnum(k,&ok);
    snprintf(k,5,"F%dTg",i); tg=readnum(k,&ok);
    printf("  F%d %-12s ist %5.0f  min %5.0f  max %5.0f  ziel %5.0f\n", i, name, ac, mn, mx, tg);
  }
  const char *temps[][2] = {
    {"TC0P","CPU nah"},{"TC0H","CPU Heatsink"},{"TC0D","CPU Die"},{"TCXC","CPU PECI"},
    {"TG0P","GPU nah"},{"TG0D","GPU Die"},{"TG0H","GPU Heatsink"},
    {"TH0P","HDD nah"},{"TH0F","HDD"},{"TH1P","HDD2"},{"TO0P","ODD"},
    {"TA0P","Umgebung"},{"TL0P","LCD"},{"Tp0P","Netzteil"},{"Tp0C","Netzteil2"},{"Tm0P","Speicher"},{"TB0T","Batterie"}};
  printf("Temperaturen (°C):\n");
  for (unsigned i=0;i<sizeof temps/sizeof temps[0];i++) {
    double v = readnum(temps[i][0],&ok);
    if (ok && v > 0 && v < 130) printf("  %s %-13s %5.1f\n", temps[i][0], temps[i][1], v);
  }
}

int main(int argc, char **argv) {
  io_service_t svc = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSMC"));
  if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &conn) != kIOReturnSuccess) { fprintf(stderr,"AppleSMC nicht erreichbar\n"); return 1; }
  IOObjectRelease(svc);
  if (argc >= 2 && !strcmp(argv[1],"status")) { status(); }
  else if (argc == 3 && !strcmp(argv[1],"read")) {
    unsigned char b[32]; UInt32 sz; char t[5];
    if (smc_read(argv[2],b,&sz,t)) { fprintf(stderr,"lesen fehlgeschlagen\n"); return 1; }
    printf("%s [%s] %u bytes:", argv[2], t, sz); for (UInt32 i=0;i<sz&&i<32;i++) printf(" %02x",b[i]); printf("\n");
  }
  else if (argc == 4 && !strcmp(argv[1],"setmin")) {
    int n = atoi(argv[2]); int rpm = atoi(argv[3]);
    if (n < 0 || n > 9 || rpm < 0 || rpm > 6000) { fprintf(stderr,"ungültig\n"); return 2; }
    char k[5]; snprintf(k,5,"F%dMn",n);
    unsigned char b[2] = { (unsigned char)((rpm<<2)>>8), (unsigned char)((rpm<<2)&0xff) };
    int r = smc_write(k,b,2);
    if (r) { fprintf(stderr,"schreiben fehlgeschlagen (%d) – root?\n", r); return 1; }
    int ok; printf("%s jetzt %.0f\n", k, readnum(k,&ok));
  }
  else if (argc == 4 && !strcmp(argv[1],"settarget")) {
    int n = atoi(argv[2]); int rpm = atoi(argv[3]);
    if (n < 0 || n > 9 || rpm < 0 || rpm > 6000) { fprintf(stderr,"ungültig\n"); return 2; }
    char k[5]; snprintf(k,5,"F%dTg",n);
    unsigned char b[2] = { (unsigned char)((rpm<<2)>>8), (unsigned char)((rpm<<2)&0xff) };
    int r = smc_write(k,b,2);
    if (r) { fprintf(stderr,"schreiben fehlgeschlagen (%d)\n", r); return 1; }
    int ok; printf("%s jetzt %.0f\n", k, readnum(k,&ok));
  }
  else if (argc == 3 && !strcmp(argv[1],"force")) {
    // Bitmaske: Bit n = Lüfter n im Zwangsmodus. 0 = alle wieder Automatik.
    int m = (int)strtol(argv[2],NULL,0);
    if (m < 0 || m > 0x7) { fprintf(stderr,"ungültig\n"); return 2; }
    unsigned char b[2] = { (unsigned char)(m>>8), (unsigned char)(m&0xff) };
    int r = smc_write("FS! ",b,2);
    if (r) { fprintf(stderr,"schreiben fehlgeschlagen (%d)\n", r); return 1; }
    int ok; printf("FS! jetzt 0x%04x\n", (int)readnum("FS! ",&ok));
  }
  else { fprintf(stderr,"Aufruf: smcfan status | read KEY | setmin N RPM | settarget N RPM | force MASK\n"); return 2; }
  IOServiceClose(conn);
  return 0;
}
