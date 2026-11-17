#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/ata/ATASMARTLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
int main(void){
  io_iterator_t it; io_object_t o;
  CFMutableDictionaryRef m = IOServiceMatching("IOBlockStorageDevice");
  if (IOServiceGetMatchingServices(kIOMasterPortDefault, m, &it)) return 1;
  while ((o = IOIteratorNext(it))) {
    CFTypeRef cap = IORegistryEntrySearchCFProperty(o, kIOServicePlane, CFSTR("SMART Capable"), kCFAllocatorDefault, 0);
    io_name_t nm; IORegistryEntryGetName(o, nm);
    printf("dev %s smart=%s\n", nm, cap ? "yes":"no");
    if (cap) { CFRelease(cap);
      IOCFPlugInInterface **pi = NULL; SInt32 score;
      kern_return_t kr = IOCreatePlugInInterfaceForService(o, kIOATASMARTUserClientTypeID, kIOCFPlugInInterfaceID, &pi, &score);
      if (kr || !pi) { printf(" plugin fail %x\n", kr); continue; }
      IOATASMARTInterface **si = NULL;
      (*pi)->QueryInterface(pi, CFUUIDGetUUIDBytes(kIOATASMARTInterfaceID), (LPVOID*)&si);
      (*pi)->Release(pi);
      if (!si) { printf(" qi fail\n"); continue; }
      ATASMARTData d; memset(&d,0,sizeof d);
      kr = (*si)->SMARTReadData(si, &d);
      printf(" read kr=%x\n", kr);
      unsigned char *b = (unsigned char*)&d;
      for (int i=0;i<30;i++){ unsigned char *a=b+2+i*12; if(!a[0])continue; if(a[0]==194||a[0]==190) printf(" attr %d raw %d %d\n",a[0],a[5],a[6]); }
      (*si)->Release(si);
    }
    IOObjectRelease(o);
  }
  return 0;
}
