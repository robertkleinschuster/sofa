// SFDownloads – subscriptions ("download new episodes automatically"): feed registry,
// subscription management, periodic checks (keepDays = download window: older episodes are not
// fetched), and the expiry of pre-buffered episodes.
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

- (void)subscribe:(SFItem *)folder {
    // Kept temporarily for older internal callers: automatic full downloads were retired.
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
    // keeps its expiry: it is no download); every episode lets go of the subscription - a deleted
    // one too (its record still says "not again"; a reference to a row deleted here would fail the
    // transaction, schema 18)
    for (SFDownloadRecord *r in _recs.allValues)
        if ([r.sub isEqualToString:fid]) {
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
    // Candidate selection belongs to bounded pre-buffering, never the full-download queue.
}

- (void)expirePrebuffers {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSMutableDictionary *watchedAt = [NSMutableDictionary new];   // id -> when it was watched (one query for all)
    for (NSDictionary *row in [[SFStore shared] rows:@"SELECT p.id, p.updated FROM progress p JOIN downloads d ON d.id = p.id "
                                                      "WHERE p.watched = 1 AND d.expires IS NOT NULL" args:nil])
        if (row[@"id"]) watchedAt[row[@"id"]] = row[@"updated"];
    NSMutableArray *writes = [NSMutableArray new];
    for (SFDownloadRecord *r in _recs.allValues) {
        if (r.state != SFDLDone || r.expires <= 0 || r.keep) continue;
        double seen = [watchedAt[r.identifier] doubleValue];
        BOOL due = now >= r.expires || (seen > 0 && now >= seen + kAfterWatchedDays * 86400.0);
        if (!due) continue;
        SFLog(@"downloads: pre-buffered %@ expired (%@) - its bytes are buffer now", r.identifier, seen > 0 ? @"watched" : @"not watched in time");
        r.state = SFDLDismissed; r.expires = 0; r.progress = 0;   // unpinned: evicted when room is needed
        [writes addObject:[self write:r]];
        [self changed:r.identifier];
    }
    if (writes.count) { [[SFStore shared] runAll:writes]; [self storageChangedSoon]; }
}

// all subscriptions against their follows' lists - local, no request (start, every 3 h with the repairs)
- (void)checkSubscriptionsNow {
    [self expirePrebuffers];
    for (SFSubscription *s in [_subs.allValues copy]) [self checkSub:s];
    SFLog(@"downloads: subscription check done");
}

@end
