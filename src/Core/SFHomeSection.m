#import "SFHomeSection.h"

@implementation SFHomeSection
+ (instancetype)section:(NSString *)identifier title:(NSString *)title priority:(NSInteger)priority
                  style:(SFTileStyle)style items:(NSArray *(^)(void))items {
    SFHomeSection *s = [self new];
    s.identifier = identifier; s.title = title; s.priority = priority; s.style = style; s.items = items;
    return s;
}
- (SFShelf *)makeShelf {
    NSArray *it = self.items ? self.items() : nil;
    if (!it.count) return nil;
    return self.grid ? [SFShelf grid:self.title style:self.style items:it] : [SFShelf shelf:self.title style:self.style items:it];
}
+ (NSArray *)shelvesFrom:(NSArray *)sections {
    NSArray *sorted = [sections sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(SFHomeSection *a, SFHomeSection *b) {
        return a.priority < b.priority ? NSOrderedAscending : a.priority > b.priority ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableArray *r = [NSMutableArray new];
    for (SFHomeSection *s in sorted) { SFShelf *sh = [s makeShelf]; if (sh) [r addObject:sh]; }
    return r;
}
@end
