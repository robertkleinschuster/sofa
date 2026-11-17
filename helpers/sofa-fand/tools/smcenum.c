#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>
typedef struct { char major, minor, build, reserved[1]; UInt16 release; } vers_t;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } plimit_t;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } keyinfo_t;
typedef struct { UInt32 key; vers_t vers; plimit_t p; keyinfo_t keyInfo; char result, status, data8; UInt32 data32; unsigned char bytes[32]; } K;
static io_connect_t c;
static int call(K*i,K*o){size_t s=sizeof(K);return IOConnectCallStructMethod(c,2,i,sizeof(K),o,&s)?-1:0;}
static void u2k(UInt32 v,char*s){s[0]=v>>24;s[1]=v>>16;s[2]=v>>8;s[3]=v;s[4]=0;}
int main(int argc,char**argv){
 io_service_t svc=IOServiceGetMatchingService(kIOMasterPortDefault,IOServiceMatching("AppleSMC"));
 if(!svc||IOServiceOpen(svc,mach_task_self(),0,&c))return 1;
 K i,o; memset(&i,0,sizeof i); memset(&o,0,sizeof o);
 i.key=('#'<<24)|('K'<<16)|('E'<<8)|'Y'; i.data8=9; call(&i,&o); i.keyInfo.dataSize=o.keyInfo.dataSize; i.data8=5; memset(&o,0,sizeof o); call(&i,&o);
 UInt32 n=(o.bytes[0]<<24)|(o.bytes[1]<<16)|(o.bytes[2]<<8)|o.bytes[3];
 const char*pre=argc>1?argv[1]:"";
 for(UInt32 x=0;x<n;x++){
  memset(&i,0,sizeof i);memset(&o,0,sizeof o); i.data8=8; i.data32=x; if(call(&i,&o)||o.result)continue;
  UInt32 key=o.key; char ks[5],ts[5]; u2k(key,ks);
  if(strncmp(ks,pre,strlen(pre)))continue;
  memset(&i,0,sizeof i);memset(&o,0,sizeof o); i.key=key;i.data8=9; if(call(&i,&o)||o.result){printf("%s ?\n",ks);continue;}
  UInt32 sz=o.keyInfo.dataSize; u2k(o.keyInfo.dataType,ts); i.keyInfo.dataSize=sz; i.data8=5; memset(&o,0,sizeof o);
  int r=call(&i,&o); printf("%s [%s] %2u:",ks,ts,sz);
  if(r||o.result){printf(" ERR(%d)\n",o.result);continue;}
  for(UInt32 j=0;j<sz&&j<32;j++)printf(" %02x",o.bytes[j]);
  if(!strcmp(ts,"sp78"))printf("  = %.2f",(signed char)o.bytes[0]+o.bytes[1]/256.0);
  if(!strcmp(ts,"fpe2"))printf("  = %.1f",((o.bytes[0]<<8)|o.bytes[1])/4.0);
  printf("\n");}
 printf("total %u\n",n);return 0;}
