#import "SFModel.h"
#import "SFApp.h"

NSError *SFError(NSString *msg) {
    return [NSError errorWithDomain:@"Sofa" code:1 userInfo:@{NSLocalizedDescriptionKey: msg ?: @"Fehler"}];
}

// Playback refs "prefix:id" are resolved by the app that owns the namespace (SFApp resolve:)
void SFResolveRef(NSString *ref, SFURLDone done) {
    Class<SFApp> a = [SFAppRegistry appForRef:ref];
    if (![a respondsToSelector:@selector(resolve:done:)]) { done(nil, SFError(@"Quelle nicht verfügbar")); return; }
    [a resolve:ref done:done];
}
void SFResolveRefOnline(NSString *ref, SFURLDone done) {
    Class<SFApp> a = [SFAppRegistry appForRef:ref];
    if ([a respondsToSelector:@selector(resolveOnline:done:)]) [a resolveOnline:ref done:done];
    else SFResolveRef(ref, done);
}

NSString *const SFDRMNotice = @"Kopiergeschützt (DRM) – auf diesem Mac nicht abspielbar";

@implementation SFBroadcast
+ (instancetype)title:(NSString *)title start:(NSDate *)start end:(NSDate *)end {
    if (!title.length || !start || !end || [end compare:start] != NSOrderedDescending) return nil;
    SFBroadcast *b = [self new];
    b.title = title; b.start = start; b.end = end;
    return b;
}
- (double)progressAt:(NSDate *)date {
    double p = [date timeIntervalSinceDate:self.start] / [self.end timeIntervalSinceDate:self.start];
    return MAX(0, MIN(1, p));
}
- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *d = [@{@"title": self.title, @"start": @(self.start.timeIntervalSince1970), @"end": @(self.end.timeIntervalSince1970)} mutableCopy];
    if (self.subtitle) d[@"subtitle"] = self.subtitle;
    if (self.plot) d[@"plot"] = self.plot.length > 600 ? [self.plot substringToIndex:600] : self.plot;
    return d;
}
+ (instancetype)broadcastWithDictionary:(NSDictionary *)d {
    if (![d isKindOfClass:[NSDictionary class]] || ![d[@"title"] isKindOfClass:[NSString class]]) return nil;
    SFBroadcast *b = [self title:d[@"title"] start:[NSDate dateWithTimeIntervalSince1970:[d[@"start"] doubleValue]]
                             end:[NSDate dateWithTimeIntervalSince1970:[d[@"end"] doubleValue]]];
    b.subtitle = [d[@"subtitle"] isKindOfClass:[NSString class]] ? d[@"subtitle"] : nil;
    b.plot = [d[@"plot"] isKindOfClass:[NSString class]] ? d[@"plot"] : nil;
    return b;
}
@end

@implementation SFItem

- (SFBroadcast *)broadcastAt:(NSDate *)date {
    for (SFBroadcast *b in self.schedule)
        if ([b.start compare:date] != NSOrderedDescending && [b.end compare:date] == NSOrderedDescending) return b;
    return nil;
}

- (SFBroadcast *)broadcastAfter:(SFBroadcast *)b {
    SFBroadcast *next = nil;
    for (SFBroadcast *x in self.schedule)
        if ([x.start compare:b.end] != NSOrderedAscending && (!next || [x.start compare:next.start] == NSOrderedAscending)) next = x;
    return next;
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *d = [NSMutableDictionary new];
    d[@"kind"] = @(self.kind);
    if (self.identifier) d[@"id"] = self.identifier;
    if (self.title) d[@"title"] = self.title;
    if (self.subtitle) d[@"subtitle"] = self.subtitle;
    if (self.plot) d[@"plot"] = self.plot.length > 2000 ? [self.plot substringToIndex:2000] : self.plot;
    if (self.image) d[@"image"] = self.image;
    if (self.backdrop) d[@"backdrop"] = self.backdrop;
    if (self.channel) d[@"channel"] = self.channel;
    if (self.source) d[@"source"] = self.source;
    if (self.date) d[@"date"] = @(self.date.timeIntervalSince1970);
    if (self.duration > 0) d[@"duration"] = @(self.duration);
    if (self.localPath) d[@"localPath"] = self.localPath;
    if (self.showRef) d[@"showRef"] = self.showRef;
    if (self.externalID) d[@"externalID"] = self.externalID;
    else if (self.playURL) d[@"url"] = self.playURL.absoluteString;   // YouTube URLs expire -> only store without externalID
    if (self.resolverRef) d[@"ref"] = self.resolverRef;
    if (self.drm) d[@"drm"] = @YES;
    if (self.geoRegion) d[@"geo"] = self.geoRegion;
    if (self.station) d[@"station"] = self.station;
    if (self.viewCount > 0) d[@"views"] = @(self.viewCount);
    if (self.schedule.count) {   // stored: what has not ended yet, a few hours ahead
        NSMutableArray *a = [NSMutableArray new];
        NSDate *now = [NSDate date];
        for (SFBroadcast *b in self.schedule) if ([b.end compare:now] == NSOrderedDescending && a.count < 12) [a addObject:[b dictionaryRepresentation]];
        if (a.count) d[@"schedule"] = a;
    }
    return d;
}

+ (instancetype)itemWithDictionary:(NSDictionary *)d {
    SFItem *i = [SFItem new];
    i.kind = [d[@"kind"] integerValue];
    i.identifier = d[@"id"];
    i.title = d[@"title"];
    i.subtitle = d[@"subtitle"];
    i.plot = d[@"plot"];
    i.image = d[@"image"];
    i.backdrop = d[@"backdrop"];
    i.channel = d[@"channel"];
    i.source = d[@"source"];
    if (d[@"date"]) i.date = [NSDate dateWithTimeIntervalSince1970:[d[@"date"] doubleValue]];
    i.duration = [d[@"duration"] doubleValue];
    i.localPath = d[@"localPath"];
    i.externalID = d[@"externalID"];
    // Stored entries (continue watching, history) may point to a download deleted in the meantime:
    // then play online and use the online image (otherwise the thumbnail is missing)
    NSFileManager *fm = [NSFileManager defaultManager];
    if (i.localPath && ![fm fileExistsAtPath:i.localPath]) i.localPath = nil;
    BOOL (^gone)(NSString *) = ^BOOL(NSString *p) { return [p hasPrefix:@"/"] && ![fm fileExistsAtPath:p]; };
    if (gone(i.backdrop)) i.backdrop = nil;
    if (gone(i.image)) i.image = [i.backdrop hasPrefix:@"http"] ? i.backdrop : nil;
    Class<SFApp> app = [SFAppRegistry appForRef:i.identifier];   // the app refreshes derived fields (picture URLs)
    if ([app respondsToSelector:@selector(updateStoredItem:)]) [app updateStoredItem:i];
    i.showRef = d[@"showRef"];
    if (i.localPath) i.playURL = [NSURL fileURLWithPath:i.localPath];
    else if (d[@"url"]) i.playURL = [NSURL URLWithString:d[@"url"]];
    i.resolverRef = d[@"ref"];
    i.drm = [d[@"drm"] boolValue];
    i.geoRegion = d[@"geo"];
    i.station = d[@"station"];
    i.viewCount = [d[@"views"] longLongValue];
    if ([d[@"schedule"] isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray new];
        for (NSDictionary *x in d[@"schedule"]) { SFBroadcast *b = [SFBroadcast broadcastWithDictionary:x]; if (b) [a addObject:b]; }
        i.schedule = a.count ? a : nil;
    }
    return i;
}

- (id)copyWithZone:(NSZone *)z {
    SFItem *i = [SFItem itemWithDictionary:[self dictionaryRepresentation]];
    i.plot = self.plot; i.style = self.style; i.resolver = self.resolver; i.pageLoader = self.pageLoader;
    i.action = self.action; i.tint = self.tint; i.themeName = self.themeName; i.badge = self.badge;
    i.playURL = self.playURL; i.inDownloadsList = self.inDownloadsList; i.streamOnly = self.streamOnly;
    i.playlistID = self.playlistID; i.heroTitle = self.heroTitle; i.heroMeta = self.heroMeta;
    return i;
}

static NSString *(^gLocalLookup)(NSString *);
void SFSetLocalFileLookup(NSString *(^lookup)(NSString *)) { gLocalLookup = [lookup copy]; }

- (void)resolveURL:(SFURLDone)done {
    void (^main)(NSURL *, NSError *) = ^(NSURL *u, NSError *e) { SFMain(^{ done(u, e); }); };
    NSString *offline = (!self.localPath && !self.streamOnly && gLocalLookup && self.identifier) ? gLocalLookup(self.identifier) : nil;
    if (offline) { main([NSURL fileURLWithPath:offline], nil); return; }
    if (self.localPath) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:self.localPath]) {
            main([NSURL fileURLWithPath:self.localPath], nil);
            return;
        }
        if (!self.resolverRef && !self.resolver) { main(nil, SFError(@"Die Datei wurde gelöscht.")); return; }
    }
    if (self.resolver) { self.resolver(main); return; }
    if (self.resolverRef) { (self.streamOnly ? SFResolveRefOnline : SFResolveRef)(self.resolverRef, main); return; }
    if (self.playURL) { main(self.playURL, nil); return; }
    main(nil, SFError(@"Kein Stream verfügbar."));
}
@end

@implementation SFShelf
+ (instancetype)shelf:(NSString *)title style:(SFTileStyle)st items:(NSArray *)items {
    SFShelf *s = [SFShelf new]; s.title = title; s.style = st; s.items = items; s.layout = SFShelfRail;
    return s;
}
+ (instancetype)grid:(NSString *)title style:(SFTileStyle)st items:(NSArray *)items {
    SFShelf *s = [self shelf:title style:st items:items]; s.layout = SFShelfGrid;
    return s;
}
@end

@implementation SFPage
+ (instancetype)page:(NSString *)title theme:(NSString *)theme shelves:(NSArray *)shelves {
    SFPage *p = [SFPage new]; p.title = title; p.themeName = theme; p.shelves = shelves;
    return p;
}
@end

NSString *SFCanonicalItem(SFItem *item, BOOL datesAsAge) {
    NSDateFormatter *iso = [NSDateFormatter new];
    iso.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    iso.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    iso.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    NSMutableDictionary *d = [[item dictionaryRepresentation] mutableCopy];
    [d removeObjectForKey:@"date"];
    [d removeObjectForKey:@"schedule"];   // stored form keeps only what has not ended: depends on now
    if (item.date) {
        if (datesAsAge) d[@"ageHours"] = @(lround(-item.date.timeIntervalSinceNow / 3600));
        else d[@"date"] = [iso stringFromDate:item.date];
        // the date label a parser puts in the subtitle ("Gestern") is relative to today: as a token
        NSString *label = SFFormatDateShort(item.date);
        if (!datesAsAge && label.length && item.subtitle) d[@"subtitle"] = [item.subtitle stringByReplacingOccurrencesOfString:label withString:@"<date>"];
    }
    if (item.schedule.count) {
        NSMutableArray *a = [NSMutableArray new];
        for (SFBroadcast *b in item.schedule) [a addObject:[NSString stringWithFormat:@"%@ %@", [iso stringFromDate:b.start], b.title]];
        d[@"schedule"] = [a componentsJoinedByString:@" / "];
    }
    NSMutableArray *parts = [NSMutableArray new];
    for (NSString *k in [d.allKeys sortedArrayUsingSelector:@selector(compare:)]) [parts addObject:[NSString stringWithFormat:@"%@=%@", k, d[k]]];
    return [parts componentsJoinedByString:@" | "];
}
