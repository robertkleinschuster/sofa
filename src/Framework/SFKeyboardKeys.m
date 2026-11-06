#import "SFKeyboardKeys.h"

@implementation SFKbKey

+ (NSArray *)rowsQwertz:(BOOL)qwertz submitTitle:(NSString *)submit {
    NSArray *lines = qwertz ? @[@"qwertzuiop", @"asdfghjklö", @"yxcvbnmäüß", @"1234567890"]
                            : @[@"abcdefghij", @"klmnopqrst", @"uvwxyzäöüß", @"1234567890"];
    NSMutableArray *rows = [NSMutableArray new];
    for (NSString *line in lines) {
        NSMutableArray *r = [NSMutableArray new];
        for (NSUInteger i = 0; i < line.length; i++) {
            SFKbKey *k = [SFKbKey new];
            k.kind = SFKbChar; k.label = [line substringWithRange:NSMakeRange(i, 1)];
            k.col = i; k.span = 1;
            [r addObject:k];
        }
        [rows addObject:r];
    }
    NSMutableArray *last = [NSMutableArray new];
    NSArray *specials = @[@[@(SFKbLayout), qwertz ? @"ABC" : @"QWERTZ", @0, @2], @[@(SFKbSpace), @"Leerzeichen", @2, @3],
                          @[@(SFKbDelete), @"Löschen", @5, @2], @[@(SFKbSubmit), submit, @7, @3]];
    for (NSArray *s in specials) {
        SFKbKey *k = [SFKbKey new];
        k.kind = [s[0] integerValue]; k.label = s[1]; k.col = [s[2] integerValue]; k.span = [s[3] integerValue];
        [last addObject:k];
    }
    [rows addObject:last];
    return rows;
}
@end
