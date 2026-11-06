// SFDownloads – subscriptions ("download new episodes automatically"): feed registry,
// subscription management, periodic checks (keepDays = download window: older episodes are not fetched).
#import "SFDownloads+Private.h"

BOOL SFHasFeed(NSString *ref) {
    return [SFAppRegistry isShowRef:ref] && [[SFAppRegistry appForRef:ref] respondsToSelector:@selector(feed:done:)];
}
void SFFetchFeed(NSString *ref, SFFeedDone done) {
    if (!SFHasFeed(ref)) { done(nil, SFError(@"Unbekannte Sendung")); return; }
    [[SFAppRegistry appForRef:ref] feed:ref done:done];
}
void SFFeedFromPage(SFPageLoader l, SFFeedDone done) {
    {
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
}

@implementation SFDownloads (Subscriptions)

#pragma mark Subscriptions

- (void)saveSub:(NSDictionary *)s {
    [[SFStore shared] run:@"INSERT OR REPLACE INTO subscriptions (id,source,title,image,keepDays,since,added) VALUES (?,?,?,?,?,?,?)"
                     args:@[s[@"id"], s[@"source"] ?: [NSNull null], s[@"title"] ?: [NSNull null], s[@"image"] ?: [NSNull null],
                            s[@"keepDays"] ?: @90, s[@"since"] ?: @0.0, s[@"added"] ?: @0.0]];
}

- (NSString *)subscriptionIDForChannel:(NSString *)channel source:(NSString *)source {
    if (!channel) return nil;
    for (NSDictionary *s in _subs.allValues)
        if ([s[@"title"] isEqualToString:channel] && (!source || [s[@"source"] isEqualToString:source])) return s[@"id"];
    return nil;
}

- (BOOL)canSubscribe:(SFItem *)folder { return folder.identifier && SFHasFeed(folder.identifier); }
- (BOOL)isSubscribed:(NSString *)fid { return fid && _subs[fid] != nil; }
- (NSArray *)subscriptions {
    return [_subs.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"title"] ?: @"" localizedCaseInsensitiveCompare:b[@"title"] ?: @""];
    }];
}

- (void)addSubscriptionRecord:(NSDictionary *)rec {
    NSMutableDictionary *s = [rec mutableCopy];
    if (!s[@"id"]) return;
    s[@"added"] = s[@"added"] ?: @([[NSDate date] timeIntervalSince1970]);
    s[@"keepDays"] = s[@"keepDays"] ?: @90;
    _subs[s[@"id"]] = s;
    [self saveSub:s];
}

- (void)subscribe:(SFItem *)folder {
    if (![self canSubscribe:folder]) return;
    NSMutableDictionary *s = [@{@"id": folder.identifier, @"source": folder.source ?: @"", @"title": folder.title ?: @"",
                                @"keepDays": @90, @"since": @0, @"added": @([[NSDate date] timeIntervalSince1970])} mutableCopy];
    if (folder.image) s[@"image"] = folder.image;
    _subs[folder.identifier] = s;
    [self saveSub:s];
    SFLog(@"downloads: auto-download on: %@ (%@)", folder.title, folder.identifier);
    [[SFFollows shared] follow:folder];   // auto-download requires following
    [self changed:folder.identifier];
    [self checkSub:s];   // a follow it already had: now; a new one: when its first check brings the list
}

- (void)unsubscribe:(NSString *)fid {
    [[SFStore shared] runAll:[self unsubscribeWrites:fid]];
}

- (NSArray *)unsubscribeWrites:(NSString *)fid {
    if (!_subs[fid]) return @[];
    SFLog(@"downloads: auto-download off: %@ (%@)", _subs[fid][@"title"], fid);
    [_subs removeObjectForKey:fid];
    NSMutableArray *writes = [NSMutableArray arrayWithObject:@[@"DELETE FROM subscriptions WHERE id=?", @[fid]]];
    // already downloaded episodes stay, but are no longer deleted automatically
    for (NSMutableDictionary *r in _recs.allValues)
        if ([r[@"sub"] isEqualToString:fid] && [r[@"state"] integerValue] != SFDLDismissed) { [r removeObjectForKey:@"sub"]; [writes addObject:[self write:r]]; }
    [self changed:fid];
    return writes;
}

// What a subscription downloads comes from its follow's list (following is a prerequisite of
// auto-download): no feed request of its own - the follow's spread refresh plan (SFRefreshPlan)
// is the only one asking the source, and its news triggers the check (SFFollowsNewItemsNotification).
// A subscription never checked before (`since` unset) takes the 3 newest, never a backfill.
- (void)checkSub:(NSMutableDictionary *)s {
    if (_subs[s[@"id"]] != s) return;
    NSArray *items = [[SFFollows shared] itemsOf:s[@"id"]];
    if (!items.count) return;   // not checked yet: its follow's news brings it here
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    double keep = ([s[@"keepDays"] doubleValue] ?: 90) * 86400;
    double since = [s[@"since"] doubleValue];   // set once, on the first check
    BOOL initial = since <= 0;
    NSInteger added = 0, n = 0;
    for (SFItem *it in items) {
        if (it.kind != SFItemVideo) continue;
        n++;
        if (initial && n > 3) {                              // new subscription: the 3 newest, never backfill older ones
            double pub3 = it.date ? [it.date timeIntervalSince1970] : now;
            if ([s[@"since"] doubleValue] <= 0) s[@"since"] = @(pub3);
            break;
        }
        double pub = it.date ? [it.date timeIntervalSince1970] : 0;
        if (pub && pub < now - keep) break;                   // older than the download window: not fetched
        if (since > 0 && pub && pub <= since) break;         // migrated subscriptions: only new ones
        if ([[SFStore shared] watched:it.identifier]) continue;
        if (added >= 5) break;                               // at most 5 per check
        if ([self enqueue:it sub:s[@"id"]]) added++;
    }
    if ([s[@"since"] doubleValue] != since) [self saveSub:s];   // the only thing a check changes
    if (added) SFLog(@"downloads: subscription %@: %ld new", s[@"title"], (long)added);
}

// all subscriptions against their follows' lists - local, no request (start, every 3 h with the repairs)
- (void)checkSubscriptionsNow {
    [self retryDueRepairs];
    for (NSMutableDictionary *s in [_subs.allValues copy]) [self checkSub:s];
    SFLog(@"downloads: subscription check done");
}

@end
