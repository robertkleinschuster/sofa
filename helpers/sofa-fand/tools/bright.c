// bright get | set 0..1 | hold 0..1 SECONDS  - backlight brightness of the built-in display (10.9)
// hold re-applies the value every 5 s (the ambient-light automatic would drift it away)
#include <IOKit/graphics/IOGraphicsLib.h>
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static io_service_t disp(void) { return CGDisplayIOServicePort(CGMainDisplayID()); }
int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: bright get | set V | hold V SECONDS\n"); return 2; }
  io_service_t s = disp(); float v;
  if (!strcmp(argv[1], "get")) { if (IODisplayGetFloatParameter(s, kNilOptions, CFSTR(kIODisplayBrightnessKey), &v)) return 1; printf("%.3f\n", v); return 0; }
  if (argc < 3) return 2;
  float w = atof(argv[2]); if (w < 0 || w > 1) return 2;
  if (!strcmp(argv[1], "set")) return IODisplaySetFloatParameter(s, kNilOptions, CFSTR(kIODisplayBrightnessKey), w) ? 1 : 0;
  if (!strcmp(argv[1], "hold") && argc > 3) {
    int sec = atoi(argv[3]);
    for (int t = 0; t <= sec; t += 5) { IODisplaySetFloatParameter(s, kNilOptions, CFSTR(kIODisplayBrightnessKey), w); sleep(5); }
    return 0;
  }
  return 2;
}
