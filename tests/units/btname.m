// sources: src/Core/SFBluetooth.m src/Core/SFBluetoothFake.m
// flags: -framework IOBluetooth
// SFBluetoothName: IOBluetooth (10.9) decodes a searched device's UTF-8 name as Latin-1 - repaired;
// names that are right already (ASCII, real Latin-1, decoded properly) stay as they are.
#import <Foundation/Foundation.h>
#import "SFBluetooth.h"
BOOL SFDevMode = NO;
static NSString *Garbled(NSString *s) {   // what IOBluetooth hands over: the UTF-8 bytes read as Latin-1
    return [[NSString alloc] initWithData:[s dataUsingEncoding:NSUTF8StringEncoding] encoding:NSISOLatin1StringEncoding];
}
int main(void) { @autoreleasepool {
    int bad = 0;
    NSString *airpods = @"AirPods Max \U0001F3A7 von Gott/Готт";
    NSArray *cases = @[@[Garbled(airpods), airpods],                  // the 2026-11-08 case
                       @[airpods, airpods],                           // decoded properly (paired list)
                       @[@"[TV]Samsung LED48", @"[TV]Samsung LED48"],  // ASCII
                       @[@"Café Lautsprecher", @"Café Lautsprecher"],  // real Latin-1: no valid UTF-8
                       @[@"", @""]];
    for (NSArray *c in cases) {
        NSString *got = SFBluetoothName(c[0]);
        if (![got isEqual:c[1]]) { fprintf(stderr, "FAIL '%s' -> '%s', want '%s'\n", [c[0] UTF8String], got.UTF8String, [c[1] UTF8String]); bad++; }
    }
    return bad ? 1 : 0;
} }
