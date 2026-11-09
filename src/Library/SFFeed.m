#import "SFFeed.h"
#import "SFCore.h"

BOOL SFHasFeed(NSString *ref) {
    return [SFAppRegistry isShowRef:ref] && [[SFAppRegistry appForRef:ref] respondsToSelector:@selector(feed:done:)];
}

void SFFetchFeed(NSString *ref, SFFeedDone done) {
    if (!SFHasFeed(ref)) { done(nil, SFError(@"Unbekannte Sendung")); return; }
    [[SFAppRegistry appForRef:ref] feed:ref done:done];
}

void SFFeedFromPage(SFPageLoader l, SFFeedDone done) {
    if (!l) { done(nil, SFError(@"Unbekannte Sendung")); return; }
    l(^(SFPage *page, NSError *e) {
        if (!page) { done(nil, e); return; }
        NSMutableArray *items = [NSMutableArray new];
        NSMutableSet *seen = [NSMutableSet new];
        for (SFShelf *sh in page.shelves) for (SFItem *i in sh.items)
            if (i.kind == SFItemVideo && i.identifier && ![seen containsObject:i.identifier]) { [seen addObject:i.identifier]; [items addObject:i]; }
        [items sortUsingComparator:^NSComparisonResult(SFItem *a, SFItem *b) {
            return [(b.date ?: [NSDate distantPast]) compare:(a.date ?: [NSDate distantPast])];
        }];
        done(items, nil);
    });
}
