// SFStore - the database schema: every step, versioned (PRAGMA user_version), and running them.
#import "SFStore+Private.h"

@implementation SFStore (Schema)

#pragma mark Schema
// The whole schema, in one place and versioned (PRAGMA user_version): each step runs once, in
// order, inside one transaction with its version bump. Never change a step that has shipped - add one.
// Tables hold Sofa's own data; an item's metadata is stored once, as its JSON (SFItem
// dictionaryRepresentation) in items, which the others reference by id; loaded into memory at launch, so besides the primary keys only the queries that page or
// sort on disk need an index (progress by updated; the response cache, in its own file, by age).

- (NSArray *)migrations {
    return @[
        // 1: the schema as it grew until 0.3.9 (tables were created by each module) - IF NOT EXISTS:
        // existing databases have them; columns added to downloads later are added where missing
        ^{
            [self exec:@"CREATE TABLE IF NOT EXISTS progress (id TEXT PRIMARY KEY, pos REAL, dur REAL, watched INTEGER DEFAULT 0, updated REAL, source TEXT, item TEXT)"];
            [self exec:@"CREATE INDEX IF NOT EXISTS progress_updated ON progress(updated)"];
            [self exec:@"CREATE TABLE IF NOT EXISTS settings (k TEXT PRIMARY KEY, v TEXT)"];
            [self exec:@"CREATE TABLE IF NOT EXISTS jcache (k TEXT PRIMARY KEY, t REAL, v BLOB)"];
            [self exec:@"CREATE TABLE IF NOT EXISTS downloads (id TEXT PRIMARY KEY, source TEXT, channel TEXT, item TEXT, path TEXT, thumb TEXT, state INTEGER, progress REAL, bytes INTEGER, added REAL, published REAL, sub TEXT, error TEXT, tries INTEGER DEFAULT 0)"];
            NSMutableSet *cols = [NSMutableSet new];
            for (NSDictionary *c in [self rowsNow:@"PRAGMA table_info(downloads)" args:nil]) if (c[@"name"]) [cols addObject:c[@"name"]];
            // failedAt: retry backoff · keep: "Behalten" · online/onlineAt: availability at the source ("Platz schaffen")
            for (NSArray *c in @[@[@"failedAt", @"REAL"], @[@"keep", @"INTEGER DEFAULT 0"], @[@"online", @"INTEGER"], @[@"onlineAt", @"REAL"]])
                if (![cols containsObject:c[0]]) [self exec:[NSString stringWithFormat:@"ALTER TABLE downloads ADD COLUMN %@ %@", c[0], c[1]]];
            [self exec:@"CREATE TABLE IF NOT EXISTS subscriptions (id TEXT PRIMARY KEY, source TEXT, title TEXT, image TEXT, keepDays INTEGER, since REAL, added REAL, lastCheck REAL)"];
            [self exec:@"CREATE TABLE IF NOT EXISTS follows (id TEXT PRIMARY KEY, source TEXT, title TEXT, image TEXT, added REAL)"];
            [self exec:@"CREATE TABLE IF NOT EXISTS follow_items (follow TEXT, id TEXT, item TEXT, date REAL, PRIMARY KEY(follow, id))"];
            [self exec:@"CREATE TABLE IF NOT EXISTS watch_later (id TEXT PRIMARY KEY, source TEXT, item TEXT, added REAL)"];
            [self exec:@"CREATE TABLE IF NOT EXISTS stats (day TEXT, event TEXT, n INTEGER, PRIMARY KEY(day, event))"];
        },
        // 2: dev instances once kept dev_* copies of the tables in this (the real) database; they
        // have their own directory now (SFSetDevInstance)
        ^{
            for (NSString *t in @[@"downloads", @"subscriptions", @"progress", @"follows", @"follow_items", @"watch_later"])
                [self exec:[NSString stringWithFormat:@"DROP TABLE IF EXISTS dev_%@", t]];
        },
        // 3: the response cache is trimmed by age (trimCache)
        ^{ [self exec:@"CREATE INDEX IF NOT EXISTS jcache_t ON jcache(t)"]; },
        // 4: settings the dev mode once wrote into the real database (dev.*, lounge.dev.*); dev
        // instances have their own database now
        ^{ [self exec:@"DELETE FROM settings WHERE k LIKE 'dev.%' OR k LIKE 'lounge.dev.%'"]; },
        // 5: data that was kept where it does not belong -
        // - feed_cache: an app's last parsed feed per followed show/channel + its change signature
        //   (was in the response cache, whose trimming dropped quiet channels first);
        // - follow_items: explicit list position instead of insertion order, no unused date;
        // - subscriptions: lastCheck was written on every check and never read
        ^{
            [self exec:@"CREATE TABLE feed_cache (id TEXT PRIMARY KEY, sig TEXT, items TEXT, updated REAL)"];
            [self exec:@"INSERT INTO feed_cache (id, sig, items, updated) SELECT 'ytchannel:' || substr(k, 9), "
                        "json_extract(CAST(v AS TEXT), '$.sig'), json_extract(CAST(v AS TEXT), '$.items'), t "
                        "FROM jcache WHERE k LIKE 'yt.feed.%' AND json_valid(CAST(v AS TEXT)) "   // a broken entry must not block the step
                        "AND json_type(CAST(v AS TEXT), '$.items') = 'array'"];
            [self exec:@"DELETE FROM jcache WHERE k LIKE 'yt.feed.%'"];
            [self exec:@"CREATE TABLE follow_items_new (follow TEXT, id TEXT, pos INTEGER, item TEXT, PRIMARY KEY(follow, id))"];
            [self exec:@"INSERT INTO follow_items_new (follow, id, pos, item) SELECT follow, id, "
                        "row_number() OVER (PARTITION BY follow ORDER BY rowid) - 1, item FROM follow_items"];
            [self exec:@"DROP TABLE follow_items"];
            [self exec:@"ALTER TABLE follow_items_new RENAME TO follow_items"];
            [self exec:@"ALTER TABLE subscriptions DROP COLUMN lastCheck"];
        },
        // 6: recent searches as rows (were one JSON array per source in the settings), newest first
        ^{
            [self exec:@"CREATE TABLE recent_searches (source TEXT, query TEXT COLLATE NOCASE, at REAL, PRIMARY KEY(source, query))"];
            [self exec:@"INSERT OR IGNORE INTO recent_searches (source, query, at) SELECT substr(s.k, 15), j.value, "
                        "strftime('%s','now') - j.key FROM settings s, json_each(s.v) j "
                        "WHERE s.k LIKE 'search.recent.%' AND json_valid(s.v) AND j.type = 'text'"];
            [self exec:@"DELETE FROM settings WHERE k LIKE 'search.recent.%'"];
        },
        // 7: when each followed show/channel was last checked (SFFollows' spread refresh plan: a
        // restart continues the plan instead of checking everything again)
        ^{ [self exec:@"ALTER TABLE follows ADD COLUMN checked REAL"]; },
        // 8: feed_cache goes - it held YouTube's parsed upload lists for the RSS change detector
        // (RSS gone since 2026-11-05); a follow keeps its own newest items (follow_items)
        ^{ [self exec:@"DROP TABLE IF EXISTS feed_cache"]; },
        // 9: a subscription is its follow's auto-download - title, picture and source live in
        // follows only (the copies here went stale: 70 of 127 on 2026-11-06). A subscription
        // without a follow (never seen, but the old adoption ran in code) becomes one first.
        ^{
            [self exec:@"INSERT OR IGNORE INTO follows (id, source, title, image, added) "
                        "SELECT id, source, title, image, added FROM subscriptions WHERE id NOT IN (SELECT id FROM follows)"];
            [self exec:@"CREATE TABLE subscriptions_new (id TEXT PRIMARY KEY, keepDays INTEGER, since REAL, added REAL)"];
            [self exec:@"INSERT INTO subscriptions_new (id, keepDays, since, added) SELECT id, keepDays, since, added FROM subscriptions"];
            [self exec:@"DROP TABLE subscriptions"];
            [self exec:@"ALTER TABLE subscriptions_new RENAME TO subscriptions"];
            [self exec:@"DELETE FROM settings WHERE k = 'follows.migrated'"];   // that adoption is this step now
        },
        // 10: the response cache moves to its own file (attachCache) - its entries go along, so the
        // update fetches nothing again; settings of removed code go (YouTube RSS feeds, the Kodi
        // import, the YouTube-account import, the old Watch Later import)
        ^{
            [self exec:@"INSERT OR IGNORE INTO cache.jcache (k, t, v) SELECT k, t, v FROM main.jcache"];
            [self exec:@"DROP TABLE main.jcache"];
            [self exec:@"DELETE FROM settings WHERE k IN ('yt.feeds.v2', 'kodi.imported', 'follows.ytAccountImported', 'watchlater.import.youtube')"];
        },
        // 11: download states said out loud - "retried later" was Failed + subscription + tries < 6,
        // "repair pending" was Done + an error text starting "repair: ", both timed by failedAt + a
        // formula in the code. Now: state 5 (Retrying) and retryAt, the time of the next attempt
        // (base 15 min doubling, as SFRetryDelay); failedAt goes.
        ^{
            [self exec:@"ALTER TABLE downloads ADD COLUMN retryAt REAL"];
            [self exec:@"UPDATE downloads SET retryAt = failedAt + 900 * (1 << (MIN(tries, 10) - 1)) "
                        "WHERE failedAt IS NOT NULL AND tries BETWEEN 1 AND 5 AND (state = 3 OR (state = 2 AND error LIKE 'repair: %'))"];
            [self exec:@"UPDATE downloads SET state = 5 WHERE state = 3 AND sub IS NOT NULL AND tries < 6"];
            [self exec:@"UPDATE downloads SET error = substr(error, 9) WHERE state = 2 AND error LIKE 'repair: %'"];
            [self exec:@"ALTER TABLE downloads DROP COLUMN failedAt"];
        },
        // 12: an item's metadata once (items) instead of a copy in every table that knows it - the
        // copies disagreed (2026-11-06: 47 titles, 24 pictures of 293 items kept twice). Merged
        // oldest snapshot first, so the newest value of each field wins and no field gets lost;
        // a download's local file and thumbnail stay with the download.
        ^{
            [self exec:@"CREATE TABLE items (id TEXT PRIMARY KEY, json TEXT NOT NULL)"];
            [self exec:@"INSERT INTO items (id, json) "
                        "SELECT id, json_remove(item, '$.localPath', "
                        "  CASE WHEN json_extract(item, '$.url') LIKE 'file:%' OR json_extract(item, '$.url') LIKE '/%' THEN '$.url' ELSE '$.localPath' END, "
                        "  CASE WHEN json_extract(item, '$.image') LIKE '/%' THEN '$.image' ELSE '$.localPath' END, "
                        "  CASE WHEN json_extract(item, '$.backdrop') LIKE '/%' THEN '$.backdrop' ELSE '$.localPath' END) "
                        "FROM (SELECT f.id, f.item, coalesce(s.checked, s.added, 0) AS t FROM follow_items f LEFT JOIN follows s ON s.id = f.follow "
                        "      UNION ALL SELECT id, item, coalesce(added, 0) FROM downloads "
                        "      UNION ALL SELECT id, item, coalesce(added, 0) FROM watch_later "
                        "      UNION ALL SELECT id, item, coalesce(updated, 0) FROM progress) "
                        "WHERE json_valid(item) AND json_type(item) = 'object' ORDER BY t "
                        "ON CONFLICT(id) DO UPDATE SET json = json_patch(json, excluded.json)"];
            for (NSString *t in @[@"progress", @"downloads", @"watch_later", @"follow_items"])
                [self exec:[NSString stringWithFormat:@"ALTER TABLE %@ DROP COLUMN item", t]];
        },
        // 13: original titles - what a video's uploader wrote, where the source's lists show another
        // title (YouTube localizes list titles to the interface language; the watch page carries the
        // original, 2026-11-08). One row per video ever opened - small, kept.
        ^{ [self exec:@"CREATE TABLE original_titles (id TEXT PRIMARY KEY, title TEXT NOT NULL)"]; },
        // 14: a download's kind, explicit: 1 = its content is the media store's tracks (no file,
        // docs/media-store.md), 0 = a file (path)
        ^{ [self exec:@"ALTER TABLE downloads ADD COLUMN store INTEGER NOT NULL DEFAULT 0 CHECK (store IN (0, 1))"]; },
        // 15: pre-buffering (docs/media-store.md phase 3): a subscription episode in the media store
        // goes at `expires` (epoch; sooner once watched); NULL = kept until the user deletes it
        ^{ [self exec:@"ALTER TABLE downloads ADD COLUMN expires REAL"]; },
        // 16: one kind of download - the media store's (agreed with the user 2026-11-08: the MP4
        // downloads go, "um auf das neue System umzusteigen und zu vereinfachen"). Their files and
        // thumbnails are deleted; a subscription episode stays dismissed (not fetched again), a manual
        // one leaves. path and store go (every download is the store's now).
        ^{
            NSFileManager *fm = [NSFileManager defaultManager];
            NSMutableSet *dirs = [NSMutableSet new];
            for (NSDictionary *r in [self rowsNow:@"SELECT path, thumb FROM downloads WHERE path IS NOT NULL AND store = 0" args:nil])
                for (NSString *k in @[@"path", @"thumb"]) {
                    NSString *f = [r[k] isKindOfClass:[NSString class]] ? r[k] : nil;
                    if (!f.length) continue;
                    [fm removeItemAtPath:f error:nil];
                    [dirs addObject:[f stringByDeletingLastPathComponent]];
                }
            for (NSString *d in dirs) {   // a show folder left empty, then its source folder (artwork does not count)
                NSString *dir = d;
                for (int up = 0; up < 2; up++, dir = [dir stringByDeletingLastPathComponent]) {
                    NSArray *left = [[fm contentsOfDirectoryAtPath:dir error:nil] filteredArrayUsingPredicate:
                                     [NSPredicate predicateWithFormat:@"NOT (SELF IN %@)", @[@".DS_Store", @"poster.jpg", @"fanart.jpg"]]];
                    if (left.count) break;
                    [fm removeItemAtPath:dir error:nil];
                }
            }
            [self exec:@"DELETE FROM downloads WHERE path IS NOT NULL AND store = 0 AND sub IS NULL"];
            [self exec:@"UPDATE downloads SET state = 4, bytes = 0, thumb = NULL, progress = 0, error = NULL, tries = 0, retryAt = NULL "
                        "WHERE path IS NOT NULL AND store = 0"];
            [self exec:@"ALTER TABLE downloads DROP COLUMN path"];
            [self exec:@"ALTER TABLE downloads DROP COLUMN store"];
        },
        // 17: a download's size is the media store's (its per-item byte sums, read live) - the copy
        // taken when a download finished went stale once its bytes changed (eviction, a refill)
        ^{
            [self exec:@"ALTER TABLE downloads DROP COLUMN bytes"];
        },
        // 18: the rules the code keeps, stated by the schema: required columns NOT NULL, value ranges as
        // CHECKs, references as foreign keys (checked at commit - DEFERRABLE INITIALLY DEFERRED - so a
        // transaction may write in any order; enforced from launch on, PRAGMA foreign_keys). Tables
        // are rebuilt (SQLite adds constraints no other way). What an old database may hold that
        // breaks them is settled first: a missing item gets a stub row (its id; the next write of
        // the item fills it) - a watched mark is not lost for want of metadata; follow items and
        // auto-downloads of a follow that is gone go; a download's vanished subscription is dropped.
        ^{
            for (NSString *t in @[@"progress", @"downloads", @"watch_later", @"follow_items"])
                [self exec:[NSString stringWithFormat:@"INSERT OR IGNORE INTO items (id, json) SELECT DISTINCT id, json_object('id', id) "
                            "FROM %@ WHERE id NOT IN (SELECT id FROM items)", t]];
            [self exec:@"DELETE FROM follow_items WHERE follow NOT IN (SELECT id FROM follows)"];
            [self exec:@"DELETE FROM subscriptions WHERE id NOT IN (SELECT id FROM follows)"];
            [self exec:@"UPDATE downloads SET sub = NULL WHERE sub IS NOT NULL AND sub NOT IN (SELECT id FROM subscriptions)"];
            NSString *const fk = @"DEFERRABLE INITIALLY DEFERRED";
            NSArray *tables = @[
                @[@"progress", [NSString stringWithFormat:@"id TEXT PRIMARY KEY REFERENCES items(id) %@, "
                   "pos REAL NOT NULL DEFAULT 0 CHECK (pos >= 0), dur REAL NOT NULL DEFAULT 0 CHECK (dur >= 0), "
                   "watched INTEGER NOT NULL DEFAULT 0 CHECK (watched IN (0, 1)), updated REAL NOT NULL, source TEXT", fk],
                  @"id, MAX(IFNULL(pos, 0), 0), MAX(IFNULL(dur, 0), 0), IFNULL(watched, 0) <> 0, IFNULL(updated, 0), source"],
                @[@"downloads", [NSString stringWithFormat:@"id TEXT PRIMARY KEY REFERENCES items(id) %@, source TEXT NOT NULL, "
                   "channel TEXT NOT NULL DEFAULT '', thumb TEXT, state INTEGER NOT NULL CHECK (state BETWEEN 0 AND 5), "
                   "progress REAL NOT NULL DEFAULT 0 CHECK (progress BETWEEN 0 AND 1), added REAL NOT NULL, published REAL, "
                   "sub TEXT REFERENCES subscriptions(id) %@, error TEXT, tries INTEGER NOT NULL DEFAULT 0 CHECK (tries >= 0), "
                   "keep INTEGER NOT NULL DEFAULT 0 CHECK (keep IN (0, 1)), online INTEGER CHECK (online IN (0, 1)), "
                   "onlineAt REAL, retryAt REAL, expires REAL", fk, fk],
                  (@"id, IFNULL(source, ''), IFNULL(channel, ''), thumb, IFNULL(state, 0), MIN(MAX(IFNULL(progress, 0), 0), 1), "
                   "IFNULL(added, 0), published, sub, error, MAX(IFNULL(tries, 0), 0), IFNULL(keep, 0) <> 0, "
                   "CASE WHEN online IS NULL THEN NULL ELSE online <> 0 END, onlineAt, retryAt, expires")],
                @[@"follows", @"id TEXT PRIMARY KEY, source TEXT NOT NULL, title TEXT NOT NULL, image TEXT, added REAL NOT NULL, checked REAL",
                  @"id, IFNULL(source, ''), IFNULL(title, ''), image, IFNULL(added, 0), checked"],
                @[@"follow_items", [NSString stringWithFormat:@"follow TEXT NOT NULL REFERENCES follows(id) %@, "
                   "id TEXT NOT NULL REFERENCES items(id) %@, pos INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (follow, id)", fk, fk],
                  @"follow, id, IFNULL(pos, 0)"],
                @[@"subscriptions", [NSString stringWithFormat:@"id TEXT PRIMARY KEY REFERENCES follows(id) %@, "
                   "keepDays INTEGER NOT NULL DEFAULT 90 CHECK (keepDays > 0), since REAL NOT NULL DEFAULT 0, added REAL NOT NULL", fk],
                  @"id, CASE WHEN keepDays > 0 THEN keepDays ELSE 90 END, IFNULL(since, 0), IFNULL(added, 0)"],
                @[@"watch_later", [NSString stringWithFormat:@"id TEXT PRIMARY KEY REFERENCES items(id) %@, "
                   "source TEXT NOT NULL DEFAULT '', added REAL NOT NULL", fk],
                  @"id, IFNULL(source, ''), IFNULL(added, 0)"],
                @[@"stats", @"day TEXT NOT NULL, event TEXT NOT NULL, n INTEGER NOT NULL DEFAULT 0 CHECK (n >= 0), PRIMARY KEY (day, event)",
                  @"day, event, MAX(IFNULL(n, 0), 0)"],
                @[@"recent_searches", @"source TEXT NOT NULL, query TEXT NOT NULL COLLATE NOCASE, at REAL NOT NULL, PRIMARY KEY (source, query)",
                  @"source, query, IFNULL(at, 0)"],
                @[@"settings", @"k TEXT PRIMARY KEY, v TEXT NOT NULL", @"k, v", @" WHERE v IS NOT NULL"],   // (nil = unset: no row)
            ];
            for (NSArray *t in tables) {
                NSString *name = t[0];
                [self exec:[NSString stringWithFormat:@"CREATE TABLE %@_new (%@)", name, t[1]]];
                NSString *where = t.count > 3 ? t[3] : @"";
                [self exec:[NSString stringWithFormat:@"INSERT INTO %@_new SELECT %@ FROM %@%@", name, t[2], name, where]];
                [self exec:[NSString stringWithFormat:@"DROP TABLE %@", name]];
                [self exec:[NSString stringWithFormat:@"ALTER TABLE %@_new RENAME TO %@", name, name]];
            }
            [self exec:@"CREATE INDEX IF NOT EXISTS progress_updated ON progress(updated)"];
            NSArray *left = [self rowsNow:@"PRAGMA foreign_key_check" args:nil];
            if (left.count) [self failStep:[NSString stringWithFormat:@"schema step 18: %lu rows break a reference (%@)", (unsigned long)left.count, left.firstObject]];
        },
        // 19: automatic downloads are gone (user 2026-11-09: pre-buffering at the resume position;
        // only "Herunterladen" fills a whole item) - and with them what only they used: their
        // settings (subscriptions, the daily start budget), a download's subscription and expiry,
        // the states dismissed (4: "do not fetch again") and retrying (5), and the attempt
        // bookkeeping only their retries read (tries, retryAt). Their rows go - one the user kept
        // ("Behalten") stays a download, a kept one that never finished is failed (the user decides);
        // their bytes stay in the media store as ordinary, evictable buffer.
        ^{
            [self exec:@"DELETE FROM downloads WHERE state = 4 OR (keep = 0 AND (sub IS NOT NULL OR expires IS NOT NULL))"];
            [self exec:@"UPDATE downloads SET state = 3 WHERE state = 5"];
            NSString *const fk = @"DEFERRABLE INITIALLY DEFERRED";
            [self exec:[NSString stringWithFormat:@"CREATE TABLE downloads_new (id TEXT PRIMARY KEY REFERENCES items(id) %@, "
                        "source TEXT NOT NULL, channel TEXT NOT NULL DEFAULT '', thumb TEXT, state INTEGER NOT NULL CHECK (state BETWEEN 0 AND 3), "
                        "progress REAL NOT NULL DEFAULT 0 CHECK (progress BETWEEN 0 AND 1), added REAL NOT NULL, published REAL, error TEXT, "
                        "keep INTEGER NOT NULL DEFAULT 0 CHECK (keep IN (0, 1)), online INTEGER CHECK (online IN (0, 1)), onlineAt REAL)", fk]];
            [self exec:@"INSERT INTO downloads_new SELECT id, source, channel, thumb, state, progress, added, published, error, keep, online, onlineAt FROM downloads"];
            [self exec:@"DROP TABLE downloads"];
            [self exec:@"ALTER TABLE downloads_new RENAME TO downloads"];
            [self exec:@"DROP TABLE subscriptions"];
            [self exec:@"DELETE FROM settings WHERE k LIKE 'downloads.subscriptionStarts.%'"];
            NSArray *left = [self rowsNow:@"PRAGMA foreign_key_check" args:nil];
            if (left.count) [self failStep:[NSString stringWithFormat:@"schema step 19: %lu rows break a reference (%@)", (unsigned long)left.count, left.firstObject]];
        },
    ];
}

- (NSInteger)pragma:(NSString *)name {
    NSDictionary *r = [self rowsNow:[@"PRAGMA " stringByAppendingString:name] args:nil].firstObject;
    return [r[name] integerValue];
}

- (void)migrate {
    NSInteger v = [self pragma:@"user_version"];
    NSArray *steps = [self migrations];
    for (NSInteger i = v; i < (NSInteger)steps.count; i++) {
        [self exec:@"BEGIN IMMEDIATE"];
        NSUInteger before = self.errorCount;
        ((dispatch_block_t)steps[i])();
        if (self.errorCount != before) {   // keep the database as it was; the step is tried again next launch
            [self exec:@"ROLLBACK"];
            SFLog(@"store: schema step %ld failed - rolled back, staying at %ld", (long)i + 1, (long)i);
            return;
        }
        [self exec:[NSString stringWithFormat:@"PRAGMA user_version=%ld", (long)i + 1]];
        [self exec:@"COMMIT"];
        SFLog(@"store: schema %ld", (long)i + 1);
    }
    // space freed by deletions goes back to the file system (incremental, see trimCache); switching an
    // existing database over takes one full VACUUM
    if ([self pragma:@"auto_vacuum"] != 2) {   // 2 = INCREMENTAL
        [self trimCacheNow];   // nothing worth copying
        NSDate *t0 = [NSDate date];
        [self exec:@"PRAGMA auto_vacuum=INCREMENTAL"];
        [self exec:@"VACUUM"];
        [self exec:@"PRAGMA wal_checkpoint(TRUNCATE)"];   // VACUUM wrote the whole database through the WAL
        SFLog(@"store: switched to incremental vacuum (%.1f s)", -[t0 timeIntervalSinceNow]);
    }
}

@end
