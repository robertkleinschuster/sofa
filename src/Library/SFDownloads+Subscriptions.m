// SFDownloads – subscriptions ("download new episodes automatically"): feed registry,
// subscription management, periodic checks (keepDays = download window: older episodes are not
// fetched), and the expiry of pre-buffered episodes (sources that fill the media store).
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

// A subscription is its follow's auto-download: the row holds only its own fields (keepDays,
// since, added); title, picture and source are the follow's (schema step 9).
- (void)saveSub:(SFSubscription *)s {
    NSArray *w = s.writeStatement;
    [[SFStore shared] run:w[0] args:w[1]];
}

- (NSString *)titleOfSub:(NSString *)sid { return [[SFFollows shared] recordOf:sid].title; }

- (NSString *)subscriptionIDForChannel:(NSString *)channel source:(NSString *)source {
    if (!channel) return nil;
    for (NSString *sid in _subs) {
        SFFollow *f = [[SFFollows shared] recordOf:sid];
        if ([f.title isEqualToString:channel] && (!source || [f.source isEqualToString:source])) return sid;
    }
    return nil;
}

- (BOOL)canSubscribe:(SFItem *)folder { return folder.identifier && SFHasFeed(folder.identifier); }
- (BOOL)isSubscribed:(NSString *)fid { return fid && _subs[fid] != nil; }

- (SFSubscription *)newSub:(NSString *)identifier keepDays:(NSInteger)keepDays since:(NSTimeInterval)since {
    SFSubscription *s = [SFSubscription new];
    s.identifier = identifier; s.keepDays = keepDays; s.since = since;
    s.added = [[NSDate date] timeIntervalSince1970];
    _subs[identifier] = s;
    [self saveSub:s];
    return s;
}

- (void)addSubscription:(SFFollow *)follow keepDays:(NSInteger)keepDays since:(NSTimeInterval)since {
    if (!follow.identifier.length) return;
    [[SFFollows shared] adopt:follow];   // following is a prerequisite of auto-download (title, picture)
    [self newSub:follow.identifier keepDays:keepDays since:since];
}

- (void)subscribe:(SFItem *)folder {
    if (![self canSubscribe:folder]) return;
    SFSubscription *s = [self newSub:folder.identifier keepDays:90 since:0];
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
    SFLog(@"downloads: auto-download off: %@", fid);
    [_subs removeObjectForKey:fid];
    NSMutableArray *writes = [NSMutableArray arrayWithObject:@[@"DELETE FROM subscriptions WHERE id=?", @[fid]]];
    // already downloaded episodes stay, but are no longer deleted automatically (a pre-buffered one
    // keeps its expiry: it is no download)
    for (SFDownloadRecord *r in _recs.allValues)
        if ([r.sub isEqualToString:fid] && r.state != SFDLDismissed) {
            r.sub = nil;
            if (r.state == SFDLRetrying) r.state = SFDLFailed;   // nobody retries it now
            [writes addObject:[self write:r]];
        }
    [self changed:fid];
    return writes;
}

// What a subscription downloads comes from its follow's list (following is a prerequisite of
// auto-download): no feed request of its own - the follow's spread refresh plan (SFRefreshPlan)
// is the only one asking the source, and its news triggers the check (SFFollowsNewItemsNotification).
// A subscription never checked before (`since` unset) takes the 3 newest, never a backfill.
- (void)checkSub:(SFSubscription *)s {
    if (_subs[s.identifier] != s) return;
    NSArray *items = [[SFFollows shared] itemsOf:s.identifier];
    if (!items.count) return;   // not checked yet: its follow's news brings it here
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    double keep = (s.keepDays ?: 90) * 86400.0;
    double since = s.since;   // set once, on the first check
    BOOL initial = since <= 0;
    NSInteger added = 0, n = 0;
    for (SFItem *it in items) {
        if (it.kind != SFItemVideo) continue;
        n++;
        if (initial && n > 3) {                              // new subscription: the 3 newest, never backfill older ones
            double pub3 = it.date ? [it.date timeIntervalSince1970] : now;
            if (s.since <= 0) s.since = pub3;
            break;
        }
        double pub = it.date ? [it.date timeIntervalSince1970] : 0;
        if (pub && pub < now - keep) break;                   // older than the download window: not fetched
        if (since > 0 && pub && pub <= since) break;         // migrated subscriptions: only new ones
        if ([[SFStore shared] watched:it.identifier]) continue;
        if (added >= 5) break;                               // at most 5 per check
        if ([self enqueue:it sub:s.identifier]) added++;
    }
    if (s.since != since) [self saveSub:s];   // the only thing a check changes
    if (added) SFLog(@"downloads: subscription %@: %ld new", [self titleOfSub:s.identifier] ?: s.identifier, (long)added);
}

- (void)expirePrebuffers {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSMutableDictionary *watchedAt = [NSMutableDictionary new];   // id -> when it was watched (one query for all)
    for (NSDictionary *row in [[SFStore shared] rows:@"SELECT p.id, p.updated FROM progress p JOIN downloads d ON d.id = p.id "
                                                      "WHERE p.watched = 1 AND d.expires IS NOT NULL" args:nil])
        if (row[@"id"]) watchedAt[row[@"id"]] = row[@"updated"];
    NSMutableArray *writes = [NSMutableArray new];
    for (SFDownloadRecord *r in _recs.allValues) {
        if (r.state != SFDLDone || !r.inStore || r.expires <= 0 || r.keep) continue;
        double seen = [watchedAt[r.identifier] doubleValue];
        BOOL due = now >= r.expires || (seen > 0 && now >= seen + kAfterWatchedDays * 86400.0);
        if (!due) continue;
        SFLog(@"downloads: pre-buffered %@ expired (%@) - its bytes are buffer now", r.identifier, seen > 0 ? @"watched" : @"not watched in time");
        r.state = SFDLDismissed; r.inStore = NO; r.expires = 0; r.bytes = 0; r.progress = 0;   // unpinned: evicted when room is needed
        [writes addObject:[self write:r]];
        [self changed:r.identifier];
    }
    if (writes.count) { [[SFStore shared] runAll:writes]; [self storageChangedSoon]; }
}

// all subscriptions against their follows' lists - local, no request (start, every 3 h with the repairs)
- (void)checkSubscriptionsNow {
    [self retryDueRepairs];
    [self expirePrebuffers];
    for (SFSubscription *s in [_subs.allValues copy]) [self checkSub:s];
    SFLog(@"downloads: subscription check done");
}

@end
