// fantest – beaufsichtigter Lüftertest. root. Bei Abbruch/Grenze: FS!=0.
// fantest FAN DUR_S RPM1 [RPM2 ...]   (FAN=-1: nur loggen, keine Eingriffe)
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/ata/ATASMARTLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <time.h>
typedef struct { char major, minor, build, reserved[1]; UInt16 release; } vers_t;
typedef struct { UInt16 version, length; UInt32 a,b,c; } plimit_t;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } keyinfo_t;
typedef struct { UInt32 key; vers_t vers; plimit_t p; keyinfo_t keyInfo; char result, status, data8; UInt32 data32; unsigned char bytes[32]; } K;
static io_connect_t c;
static UInt32 k2u(const char*s){return ((UInt32)s[0]<<24)|((UInt32)s[1]<<16)|((UInt32)s[2]<<8)|(UInt32)s[3];}
static int call(K*i,K*o){size_t s=sizeof(K);return IOConnectCallStructMethod(c,2,i,sizeof(K),o,&s)?-1:0;}
static int rd(const char*k,unsigned char*b){K i,o;memset(&i,0,sizeof i);memset(&o,0,sizeof o);i.key=k2u(k);i.data8=9;
 if(call(&i,&o)||o.result)return -1;i.keyInfo.dataSize=o.keyInfo.dataSize;i.data8=5;memset(&o,0,sizeof o);if(call(&i,&o)||o.result)return -1;memcpy(b,o.bytes,4);return 0;}
static int wr(const char*k,const unsigned char*b,UInt32 n){K i,o;memset(&i,0,sizeof i);memset(&o,0,sizeof o);i.key=k2u(k);i.data8=6;i.keyInfo.dataSize=n;memcpy(i.bytes,b,n);
 if(call(&i,&o)||o.result)return -1;return 0;}
static double temp(const char*k){unsigned char b[4];if(rd(k,b))return -99;return (signed char)b[0]+b[1]/256.0;}
static double rpm(const char*k){unsigned char b[4];if(rd(k,b))return -1;return ((b[0]<<8)|b[1])/4.0;}
static void setfs(int m){unsigned char b[2]={0,(unsigned char)m};wr("FS! ",b,2);}
static void settg(int f,int r){char k[5];snprintf(k,5,"F%dTg",f);unsigned char b[2]={(unsigned char)((r<<2)>>8),(unsigned char)((r<<2)&0xff)};wr(k,b,2);}
static int fsval(void){unsigned char b[4];if(rd("FS! ",b))return -1;return (b[0]<<8)|b[1];}
static void reset(void){setfs(0);setfs(0);}
static void onsig(int s){reset();_exit(128+s);}
static IOATASMARTInterface **si;
static int hdd(void){ if(!si){io_iterator_t it;io_object_t o;IOServiceGetMatchingServices(kIOMasterPortDefault,IOServiceMatching("IOBlockStorageDevice"),&it);
  while((o=IOIteratorNext(it))){CFTypeRef cap=IORegistryEntrySearchCFProperty(o,kIOServicePlane,CFSTR("SMART Capable"),kCFAllocatorDefault,0);
   if(cap&&!si){CFRelease(cap);IOCFPlugInInterface**pi=0;SInt32 sc;if(!IOCreatePlugInInterfaceForService(o,kIOATASMARTUserClientTypeID,kIOCFPlugInInterfaceID,&pi,&sc)&&pi){
    (*pi)->QueryInterface(pi,CFUUIDGetUUIDBytes(kIOATASMARTInterfaceID),(LPVOID*)&si);(*pi)->Release(pi);}}IOObjectRelease(o);}}
 if(!si)return -1;ATASMARTData d;if((*si)->SMARTReadData(si,&d))return -1;unsigned char*b=(unsigned char*)&d;
 for(int i=0;i<30;i++){unsigned char*a=b+2+i*12;if(a[0]==194)return a[5];}return -1;}
// Grenzen (Test)
#define L_GPU 75
#define L_CPU 70
#define L_CORE 85
#define L_HDD 50
#define L_ODD 55
#define L_PSU 92
int main(int argc,char**argv){
 if(argc<4){fprintf(stderr,"fantest FAN DUR RPM...\n");return 2;}
 io_service_t svc=IOServiceGetMatchingService(kIOMasterPortDefault,IOServiceMatching("AppleSMC"));
 if(!svc||IOServiceOpen(svc,mach_task_self(),0,&c))return 1;
 int fan=atoi(argv[1]),dur=atoi(argv[2]);
 signal(SIGINT,onsig);signal(SIGTERM,onsig);signal(SIGHUP,SIG_IGN);signal(SIGPIPE,SIG_IGN);atexit(reset);
 reset(); setvbuf(stdout,0,_IOLBF,0);
 printf("# t step tgt F0 F1 F2 FS | CPUp core GPUd GPUh ODD HDD PSUh Amb PCH\n");
 time_t t0=time(0);int hd=hdd();time_t lh=0;
 for(int s=3;s<argc;s++){int r=atoi(argv[s]);
  if(fan>=10){for(int f=0;f<3;f++)if((fan-10)&(1<<f))settg(f,r);setfs(fan-10);}else if(fan>=0){settg(fan,r);setfs(1<<fan);}
  time_t ts=time(0);
  while(time(0)-ts<dur){
   if(time(0)-lh>=20){hd=hdd();lh=time(0);}
   double cp=temp("TC0P"),gd=temp("TG0D"),gh=temp("TG0H"),od=temp("TO0P"),ps=temp("Tp2H"),am=temp("TA0P"),pc=temp("TPCD");
   double co=0;const char*cs[]={"TC0c","TC1c","TC2c","TC3c"};for(int j=0;j<4;j++){double v=temp(cs[j]);if(v>co)co=v;}
   printf("%4ld %d %4d %5.0f %5.0f %5.0f %d | %5.1f %5.1f %5.1f %5.1f %5.1f %3d %5.1f %5.1f %5.1f\n",(long)(time(0)-t0),s-3,fan>=0?r:-1,
     rpm("F0Ac"),rpm("F1Ac"),rpm("F2Ac"),fsval(),cp,co,gd,gh,od,hd,ps,am,pc);
   const char*why=0;
   if(cp<-50||gd<-50||od<-50||ps<-50)why="Sensor";else if(hd<0)why="HDD-Sensor";
   else if(gd>=L_GPU)why="GPU";else if(cp>=L_CPU)why="CPU";else if(co>=L_CORE)why="Kern";else if(hd>=L_HDD)why="HDD";else if(od>=L_ODD)why="ODD";else if(ps>=L_PSU)why="PSU";
   if(why){reset();printf("# ABBRUCH Grenze %s, FS!=%d\n",why,fsval());return 3;}
   sleep(10);}
 }
 reset();printf("# fertig, FS!=%d\n",fsval());return 0;}
