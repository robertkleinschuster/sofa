// SFDownloads – Abos ("Neue Folgen automatisch laden"): Feed-Registry, Abo-Verwaltung,
// regelmäßige Prüfung, Behaltefrist und Smart-Delete gesehener Abo-Folgen.
#import "SFDownloads+Private.h"

static NSMutableDictionary *gFeeds;   // prefix -> SFFeedFetcher
void SFRegisterFeed(NSString *prefix, SFFeedFetcher f) { if (!gFeeds) gFeeds = [NSMutableDictionary new]; gFeeds[prefix] = [f copy]; }
SFFeedFetcher SFFeedFor(NSString *identifier) { NSRange r = [identifier rangeOfString:@":"]; return r.location == NSNotFound ? nil : gFeeds[[identifier substringToIndex:r.location]]; }
void SFRegisterFeedFromLoader(NSString *prefix, SFPageLoader (^loaderFor)(NSString *ref)) {
    SFRegisterFeed(prefix, ^(NSString *ref, void (^done)(NSArray *, NSError *)) {
        SFPageLoader l = loaderFor(ref);
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
    });
}

@implementation SFDownloads (Subscriptions)

#pragma mark Abos

- (void)saveSub:(NSDictionary *)s {
    [[SFStore shared] run:@"INSERT OR REPLACE INTO subscriptions (id,source,title,image,keepDays,since,added,lastCheck) VALUES (?,?,?,?,?,?,?,?)"
                     args:@[s[@"id"], s[@"source"] ?: [NSNull null], s[@"title"] ?: [NSNull null], s[@"image"] ?: [NSNull null],
                            s[@"keepDays"] ?: @90, s[@"since"] ?: @0.0, s[@"added"] ?: @0.0, s[@"lastCheck"] ?: @0.0]];
}

- (NSString *)subscriptionIDForChannel:(NSString *)channel source:(NSString *)source {
    if (!channel) return nil;
    for (NSDictionary *s in _subs.allValues)
        if ([s[@"title"] isEqualToString:channel] && (!source || [s[@"source"] isEqualToString:source])) return s[@"id"];
    return nil;
}

- (BOOL)canSubscribe:(SFItem *)folder { return folder.identifier && gFeeds[prefixOf(folder.identifier)] != nil; }
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
    SFLog(@"downloads: Automatisch herunterladen an: %@ (%@)", folder.title, folder.identifier);
    [[SFFollows shared] follow:folder];   // Automatisch herunterladen setzt Folgen voraus
    [self changed:folder.identifier];
    [self checkSub:s initial:YES done:nil];
}

- (void)unsubscribe:(NSString *)fid {
    if (!_subs[fid]) return;
    SFLog(@"downloads: Automatisch herunterladen aus: %@ (%@)", _subs[fid][@"title"], fid);
    [_subs removeObjectForKey:fid];
    [[SFStore shared] run:@"DELETE FROM subscriptions WHERE id=?" args:@[fid]];
    // bereits geladene Folgen bleiben, werden aber nicht mehr automatisch gelöscht
    for (NSMutableDictionary *r in _recs.allValues)
        if ([r[@"sub"] isEqualToString:fid] && [r[@"state"] integerValue] != SFDLDismissed) { [r removeObjectForKey:@"sub"]; [self save:r]; }
    [self changed:fid];
}

- (void)checkSub:(NSMutableDictionary *)s initial:(BOOL)initial done:(dispatch_block_t)done {
    SFFeedFetcher f = gFeeds[prefixOf(s[@"id"])];
    if (!f) { if (done) done(); return; }
    f(restOf(s[@"id"]), ^(NSArray *items, NSError *e) {
        SFMain(^{
            if (self->_subs[s[@"id"]] != s) { if (done) done(); return; }   // inzwischen abbestellt/ersetzt
            if (!items) { SFLog(@"downloads: Abo %@: %@", s[@"title"], e.localizedDescription); if (done) done(); return; }
            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
            double keep = ([s[@"keepDays"] doubleValue] ?: 90) * 86400;
            double since = [s[@"since"] doubleValue];
            NSInteger added = 0, n = 0;
            for (SFItem *it in items) {
                if (it.kind != SFItemVideo) continue;
                n++;
                if (initial && n > 3) {                              // neues Abo: die 3 neuesten, Älteres nie nachladen
                    double pub3 = it.date ? [it.date timeIntervalSince1970] : now;
                    if ([s[@"since"] doubleValue] <= 0) s[@"since"] = @(pub3);
                    break;
                }
                double pub = it.date ? [it.date timeIntervalSince1970] : 0;
                if (pub && pub < now - keep) break;                   // älter als Behaltefrist
                if (since > 0 && pub && pub <= since) break;         // migrierte Abos: nur Neues
                if ([[SFStore shared] watched:it.identifier]) continue;
                if (added >= 5) break;                               // pro Prüfung höchstens 5
                if ([self enqueue:it sub:s[@"id"]]) added++;
            }
            s[@"lastCheck"] = @(now);
            [self saveSub:s];
            if (added) SFLog(@"downloads: Abo %@: %ld neu", s[@"title"], (long)added);
            if (done) done();
        });
    });
}

- (void)checkSubscriptionsNow {
    [self retryDueRepairs];
    if (_checking || ![SFNet isOnline]) return;
    _checking = YES;
    [self cleanup];
    NSArray *all = [_subs.allValues copy];
    __block NSUInteger i = 0;
    __block void (^next)(void);
    __weak SFDownloads *ws = self;
    next = ^{
        SFDownloads *me = ws;
        if (!me) return;
        if (i >= all.count) { me->_checking = NO; next = nil; SFLog(@"downloads: Abo-Prüfung fertig"); return; }
        NSMutableDictionary *s = all[i++];
        // nacheinander, mit kleiner Pause (schont die Quellen)
        __block BOOL called = NO;
        dispatch_block_t step = ^{
            if (called) return;
            called = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (next) next(); });
        };
        [me checkSub:s initial:NO done:step];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(90 * NSEC_PER_SEC)), dispatch_get_main_queue(), step);   // Zeitlimit je Feed
    };
    next();
}

// Nutzer-Einstellung -> SFSettings; früher in SQLite (downloads.deleteWatched): einmalig übernehmen
- (BOOL)deletesWatched {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *old = [[SFStore shared] setting:@"downloads.deleteWatched"];
        if (old.length) {
            SFSetDeleteWatchedDownloads(![old isEqualToString:@"0"]);
            [[SFStore shared] setSetting:@"" forKey:@"downloads.deleteWatched"];
        }
    });
    return SFDeleteWatchedDownloads();
}
- (void)setDeletesWatched:(BOOL)on {
    SFSetDeleteWatchedDownloads(on);
    _generation++;
    [self changed:nil];
    SFLog(@"downloads: gesehene Abo-Folgen löschen %@", on ? @"an" : @"aus");
    if (on) [self cleanup];
}

// Behaltefrist: Abo-Folgen nach keepDays (ab Veröffentlichung) löschen;
// Smart Downloads: gesehene Abo-Folgen 1 Tag nach dem Ansehen
- (void)cleanup {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (self.deletesWatched) {
        NSMutableDictionary *seen = [NSMutableDictionary new];   // id -> Zeitpunkt "gesehen"
        for (NSDictionary *row in [[SFStore shared] rows:@"SELECT id, updated FROM progress WHERE watched=1" args:nil]) seen[row[@"id"]] = row[@"updated"];
        for (NSMutableDictionary *r in [_recs.allValues copy]) {
            if ([r[@"state"] integerValue] != SFDLDone || !r[@"sub"]) continue;
            NSNumber *w = seen[r[@"id"]];
            if (w && [w doubleValue] < now - 86400) {
                SFLog(@"downloads: gesehen, gelöscht: %@", r[@"id"]);
                [self remove:r[@"id"]];
            }
        }
    }
    for (NSMutableDictionary *r in [_recs.allValues copy]) {
        if ([r[@"state"] integerValue] != SFDLDone || !r[@"sub"]) continue;
        NSDictionary *s = _subs[r[@"sub"]];
        double keep = ([s[@"keepDays"] doubleValue] ?: 90) * 86400;
        double pub = [r[@"published"] doubleValue] ?: [r[@"added"] doubleValue];
        if (pub && pub < now - keep) {
            SFLog(@"downloads: Behaltefrist abgelaufen: %@", r[@"id"]);
            [self remove:r[@"id"]];
        }
    }
}

@end
