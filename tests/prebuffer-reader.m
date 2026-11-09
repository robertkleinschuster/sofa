// Standalone local-file probe; tools/test-prebuffer-reader builds its fixture.
#import "SFPrebufferReader.h"
#include <math.h>
int main(int argc, char **argv) { @autoreleasepool {
 if (argc != 2) return 3;
 SFPrebufferRead *cancel=[SFPrebufferRead new];cancel.cancelled=YES;
 NSDictionary *a=[SFPrebufferReader readURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]] audio:nil position:70 request:cancel];
 if(![a[@"reason"] isEqual:@"cancelled"]) return 1;
 NSDictionary *b=[SFPrebufferReader readURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]] audio:nil position:70 request:[SFPrebufferRead new]];
 NSLog(@"reader: %@",b);
 double ahead=[b[@"buffered"] doubleValue];
 return [b[@"reason"] isEqual:@"bounded"] && fabs([b[@"position"] doubleValue]-70)<1 && ahead>=8 && ahead<=15 ? 0 : 2;
} }
