// SFStore - the database schema: every step, versioned (PRAGMA user_version), and running them.
#import "SFStore+Private.h"

@implementation SFStore (Schema)

#pragma mark Schema
// The whole schema, in one place and versioned (PRAGMA user_version): each step runs once, in
// order, inside one transaction with its version bump. Never change a step that has shipped - add one.
// Tables hold Sofa's own data; items are stored as their JSON (SFItem dictionaryRepresentation)
// and loaded into memory at launch, so besides the primary keys only the queries that page or
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
