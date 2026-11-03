#import "SFMigration.h"
#import "SFDownloads.h"
#import "SFStore.h"
#import "SFYouTube.h"

static NSString *norm(NSString *s) {
    s = [s stringByReplacingOccurrencesOfString:@"：" withString:@":"];   // ytdl-sub ersetzt ":" im Ordnernamen
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].precomposedStringWithCanonicalMapping;
}

// subscriptions-kodi.yaml: "profil:" auf Spalte 0, darunter "  Name: URL"
static NSDictionary *readYAML(void) {
    NSString *y = [NSString stringWithContentsOfFile:[NSHomeDirectory() stringByAppendingPathComponent:@"ytdl-sub/subscriptions-kodi.yaml"] encoding:NSUTF8StringEncoding error:nil];
    NSMutableDictionary *out = [NSMutableDictionary new];   // norm(name) -> @{name, profile, url}
    NSString *profile = nil;
    for (NSString *line in [y componentsSeparatedByString:@"\n"]) {
        if (!line.length || [line hasPrefix:@"#"]) continue;
        if (![line hasPrefix:@" "]) { NSRange c = [line rangeOfString:@":"]; profile = c.location != NSNotFound ? [line substringToIndex:c.location] : nil; continue; }
        NSRange u = [line rangeOfString:@": http"];
        if (!profile || u.location == NSNotFound) continue;
        NSString *name = [line substringToIndex:u.location];
        name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (name.length >= 2 && ([name hasPrefix:@"'"] || [name hasPrefix:@"\""])) name = [name substringWithRange:NSMakeRange(1, name.length - 2)];
        NSString *url = [[line substringFromIndex:u.location + 2] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        out[norm(name)] = @{@"name": name, @"profile": profile, @"url": url};
    }
    return out;
}

static NSDictionary *readNFO(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return nil;
    NSXMLDocument *doc = [[NSXMLDocument alloc] initWithData:data options:0 error:nil];
    NSMutableDictionary *d = [NSMutableDictionary new];
    for (NSXMLNode *n in doc.rootElement.children)
        if (n.kind == NSXMLElementKind && n.name && !d[n.name]) d[n.name] = n.stringValue ?: @"";
    return d;
}

static NSString *sourceFor(NSString *profile, NSString *genre) {
    if ([profile hasPrefix:@"zdf"]) return @"zdf";
    if ([profile hasPrefix:@"ard"]) return @"ard";
    if ([profile hasPrefix:@"yt"]) return @"youtube";
    NSString *g = genre.lowercaseString;
    for (NSString *s in @[@"zdf", @"ard", @"orf", @"ccc"]) if ([g isEqualToString:s]) return s;
    return @"youtube";
}

static NSString *lastPathPart(NSString *url) {
    NSString *p = [(NSURL *)[NSURL URLWithString:url] path];
    while ([p hasSuffix:@"/"]) p = [p substringToIndex:p.length - 1];
    return p.lastPathComponent;
}

static BOOL isVideo(NSString *f) {
    NSString *e = f.pathExtension.lowercaseString;
    return ![f hasPrefix:@"."] && ([e isEqualToString:@"mp4"] || [e isEqualToString:@"m4v"] || [e isEqualToString:@"mkv"] || [e isEqualToString:@"mov"]);
}

// Ein Video aus NFO + Datei; Identität so wie die Online-Provider sie vergeben
static SFItem *episodeItem(NSString *vp, NSDictionary *n, NSString *source, NSString *channel) {
    static NSDateFormatter *df;
    if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"yyyy-MM-dd"; df.timeZone = [NSTimeZone localTimeZone]; }
    SFItem *e = [SFItem new];
    e.kind = SFItemVideo;
    e.source = source; e.themeName = source;
    e.channel = channel;
    NSString *uid = [n[@"uniqueid"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *plot = n[@"plot"];
    NSString *firstLine = [plot hasPrefix:@"http"] ? [plot componentsSeparatedByString:@"\n"].firstObject : nil;
    NSString *ident = nil;
    if ([source isEqualToString:@"youtube"]) {
        NSString *vid = uid.length == 11 ? uid : nil;
        NSRange v = [firstLine rangeOfString:@"watch?v="];
        if (!vid && v.location != NSNotFound && firstLine.length >= NSMaxRange(v) + 11) vid = [firstLine substringWithRange:NSMakeRange(NSMaxRange(v), 11)];
        if (vid) { ident = [@"yt:" stringByAppendingString:vid]; e.externalID = vid; }
    } else if ([source isEqualToString:@"zdf"] && uid.length) {
        ident = [@"zdf:" stringByAppendingString:uid];
    } else if ([source isEqualToString:@"ard"] && [firstLine rangeOfString:@"ardmediathek.de/video/"].location != NSNotFound) {
        ident = [@"ard:" stringByAppendingString:lastPathPart(firstLine)];
    }
    if (ident) e.resolverRef = ident;
    else ident = [NSString stringWithFormat:@"local:%@-%@", source, uid.length ? uid : vp.lastPathComponent.stringByDeletingPathExtension];
    e.identifier = ident;
    NSString *t = n[@"title"];
    if (!t.length) {
        t = vp.lastPathComponent.stringByDeletingPathExtension;
        NSRange dash = [t rangeOfString:@" - "];
        if (dash.location != NSNotFound && dash.location < 20) t = [t substringFromIndex:NSMaxRange(dash)];
    }
    e.title = t;
    if (firstLine) plot = [[plot substringFromIndex:firstLine.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    e.plot = plot;
    NSString *aired = [n[@"aired"] length] ? n[@"aired"] : n[@"premiered"];
    e.date = aired.length >= 10 ? [df dateFromString:[aired substringToIndex:10]] : nil;
    if (!e.date) e.date = [[NSFileManager defaultManager] attributesOfItemAtPath:vp error:nil].fileModificationDate;
    e.duration = [n[@"runtime"] doubleValue] * 60;
    e.style = SFTileStyleLandscape;
    return e;
}

// Abo-Ziel aus der ytdl-sub-URL; @handles brauchen eine Anfrage (done: id oder nil)
static void subscriptionID(NSString *source, NSString *url, void (^done)(NSString *sid)) {
    if ([source isEqualToString:@"zdf"]) { done([@"zdfshow:" stringByAppendingString:lastPathPart(url)]); return; }
    if ([source isEqualToString:@"ard"]) { done([@"ardshow:" stringByAppendingString:lastPathPart(url)]); return; }
    NSRange c = [url rangeOfString:@"/channel/"];
    if (c.location != NSNotFound) { done([@"ytchannel:" stringByAppendingString:lastPathPart(url)]); return; }
    NSString *u = [url stringByReplacingOccurrencesOfString:@"://m.youtube.com" withString:@"://www.youtube.com"];
    if ([u hasSuffix:@"/videos"]) u = [u substringToIndex:u.length - 7];
    [SFYouTube resolveChannelURL:u done:^(NSString *cid) { done(cid ? [@"ytchannel:" stringByAppendingString:cid] : nil); }];
}

void SFMigrateLibraryIfNeeded(void) {
    NSString *root;
    if (SFDevMode) {
        root = [NSProcessInfo processInfo].environment[@"SOFA_MIGRATE_ROOT"];
        if (!root.length) return;
    } else {
        if ([[SFStore shared] setting:@"migration.tvshows"]) return;
        root = [NSHomeDirectory() stringByAppendingPathComponent:@"TV Shows"];
    }
    NSFileManager *fm0 = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm0 fileExistsAtPath:root isDirectory:&isDir] || !isDir) {
        if (!SFDevMode) [[SFStore shared] setSetting:@"none" forKey:@"migration.tvshows"];
        return;
    }
    SFLog(@"migration: übernehme %@", root);
    SFBackground(^{
        // 1) Bestand lesen (NFOs) – Hintergrund
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *yaml = readYAML();
        NSMutableArray *shows = [NSMutableArray new];
        for (NSString *dir in [[fm contentsOfDirectoryAtPath:root error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
            NSString *sp = [root stringByAppendingPathComponent:dir];
            BOOL d = NO;
            if ([dir hasPrefix:@"."] || ![fm fileExistsAtPath:sp isDirectory:&d] || !d) continue;
            NSDictionary *tv = readNFO([sp stringByAppendingPathComponent:@"tvshow.nfo"]);
            NSDictionary *y = yaml[norm(dir)] ?: (tv[@"title"] ? yaml[norm(tv[@"title"])] : nil);
            NSString *source = sourceFor(y[@"profile"], tv[@"genre"]);
            NSString *channel = y[@"name"] ?: ([tv[@"title"] length] ? tv[@"title"] : norm(dir));
            NSMutableArray *eps = [NSMutableArray new];
            NSDirectoryEnumerator *en = [fm enumeratorAtPath:sp];
            for (NSString *rel in en) {
                if (!isVideo(rel.lastPathComponent)) continue;
                NSString *vp = [sp stringByAppendingPathComponent:rel];
                NSString *base = vp.stringByDeletingPathExtension;
                SFItem *e = episodeItem(vp, readNFO([base stringByAppendingPathExtension:@"nfo"]) ?: @{}, source, channel);
                NSString *thumb = [base stringByAppendingString:@"-thumb.jpg"];
                if (![fm fileExistsAtPath:thumb]) thumb = [base stringByAppendingPathExtension:@"jpg"];
                NSString *oldID = [@"local:" stringByAppendingString:[dir stringByAppendingPathComponent:rel]];
                [eps addObject:@{@"item": e, @"path": vp, @"thumb": thumb, @"old": oldID}];
            }
            NSMutableDictionary *s = [@{@"dir": sp, @"source": source, @"channel": channel, @"eps": eps} mutableCopy];
            if (y) { s[@"url"] = y[@"url"]; s[@"key"] = norm(y[@"name"]); }
            [shows addObject:s];
        }
        // Abos ohne vorhandenen Ordner (nur echte Übernahme, nicht beim Dev-Test)
        if (!SFDevMode) {
            NSSet *have = [NSSet setWithArray:[shows valueForKey:@"key"]];
            for (NSString *k in yaml) if (![have containsObject:k]) {
                NSDictionary *y = yaml[k];
                [shows addObject:@{@"dir": @"", @"source": sourceFor(y[@"profile"], nil), @"channel": y[@"name"], @"eps": @[], @"url": y[@"url"], @"key": k}];
            }
        }
        // 2) Übernehmen – Main-Thread (SFDownloads/SFStore), Verschieben = Umbenennen
        SFMain(^{
            SFDownloads *dl = [SFDownloads shared];
            SFStore *st = [SFStore shared];
            NSUInteger moved = 0, dup = 0, failed = 0, prog = 0;
            unsigned long long bytes = 0;
            NSMutableArray *subs = [NSMutableArray new];
            for (NSDictionary *s in shows) {
                NSDate *newest = nil;
                for (NSDictionary *ep in s[@"eps"]) {
                    SFItem *e = ep[@"item"];
                    NSError *err = nil;
                    unsigned long long sz = [[fm attributesOfItemAtPath:ep[@"path"] error:nil] fileSize];
                    if ([dl adoptFile:ep[@"path"] item:e thumb:ep[@"thumb"] subscription:nil error:&err]) { moved++; bytes += sz; }
                    else if ([dl fileFor:e.identifier]) dup++;
                    else { failed++; SFLog(@"migration: FEHLER %@: %@", ep[@"path"], err.localizedDescription); continue; }
                    if (!newest || [e.date compare:newest] == NSOrderedDescending) newest = e.date;
                    // Fortschritt/gesehen wandert mit (Dev: gemeinsame DB -> nicht anfassen)
                    if (!SFDevMode) { if ([st moveProgress:ep[@"old"] toItem:e]) prog++; }
                    else if ([st watched:ep[@"old"]]) prog++;
                }
                // Poster/Fanart der Sendung in deren Sofa-Ordner
                NSString *target = [dl folderForSource:s[@"source"] channel:s[@"channel"]];
                if ([s[@"dir"] length]) for (NSString *img in @[@"poster.jpg", @"fanart.jpg"]) {
                    NSString *src = [s[@"dir"] stringByAppendingPathComponent:img], *dst = [target stringByAppendingPathComponent:img];
                    if ([fm fileExistsAtPath:src] && [fm fileExistsAtPath:target] && ![fm fileExistsAtPath:dst]) [fm moveItemAtPath:src toPath:dst error:nil];
                }
                if (s[@"url"]) [subs addObject:@{@"show": s, @"newest": newest ?: [NSDate date]}];
            }
            SFLog(@"migration: %lu Videos übernommen (%.1f GB), %lu doppelt, %lu Fehler, Fortschritt %lu%@",
                  (unsigned long)moved, bytes / 1e9, (unsigned long)dup, (unsigned long)failed, (unsigned long)prog, SFDevMode ? @" (Dev: Fortschritt nur gezählt)" : @"");
            [[NSNotificationCenter defaultCenter] postNotificationName:SFDownloadsDidChangeNotification object:nil];
            // 3) Abos (ohne Bestand: ab jetzt; mit Bestand: nur Neueres als die neueste Folge)
            __block NSUInteger okSubs = 0;
            NSMutableArray *unresolved = [NSMutableArray new];
            dispatch_block_t finish = ^{
                SFLog(@"migration: %lu Abos übernommen%@", (unsigned long)okSubs,
                      unresolved.count ? [@", nicht auflösbar: " stringByAppendingString:[unresolved componentsJoinedByString:@", "]] : @"");
                if (SFDevMode) return;
                [st setSetting:[NSString stringWithFormat:@"%lu/%lu/%lu", (unsigned long)moved, (unsigned long)failed, (unsigned long)okSubs] forKey:@"migration.tvshows"];
                if (unresolved.count) [st setSetting:[unresolved componentsJoinedByString:@"\n"] forKey:@"migration.unresolved"];
                // 4) Rest in den Papierkorb – nur wenn kein Video zurückgeblieben ist
                NSUInteger left = 0;
                for (NSString *rel in [fm enumeratorAtPath:root]) if (isVideo(rel.lastPathComponent)) left++;
                if (left) { SFLog(@"migration: %lu Videos verbleiben in %@ – Ordner bleibt", (unsigned long)left, root); return; }
                NSError *te = nil;
                if ([fm trashItemAtURL:[NSURL fileURLWithPath:root] resultingItemURL:nil error:&te]) SFLog(@"migration: %@ in den Papierkorb", root);
                else SFLog(@"migration: Papierkorb fehlgeschlagen: %@", te.localizedDescription);
            };
            // nacheinander (je eine kleine Anfrage für @handles)
            __block NSUInteger idx = 0;
            __block void (^next)(void);
            next = ^{
                if (idx >= subs.count) { dispatch_block_t f = finish; next = nil; f(); return; }   // next=nil gibt diesen Block frei
                NSDictionary *x = subs[idx++];
                NSDictionary *s = x[@"show"];
                subscriptionID(s[@"source"], s[@"url"], ^(NSString *sid) {
                    SFMain(^{
                        if (sid) {
                            NSMutableDictionary *rec = [@{@"id": sid, @"source": s[@"source"], @"title": s[@"channel"], @"keepDays": @90,
                                                          @"since": @([x[@"newest"] timeIntervalSince1970])} mutableCopy];
                            NSString *poster = [[dl folderForSource:s[@"source"] channel:s[@"channel"]] stringByAppendingPathComponent:@"poster.jpg"];
                            if ([fm fileExistsAtPath:poster]) rec[@"image"] = poster;
                            if (![dl isSubscribed:sid]) { [dl addSubscriptionRecord:rec]; okSubs++; }
                        } else [unresolved addObject:s[@"channel"]];
                        if (next) next();
                    });
                });
            };
            next();
        });
    });
}
