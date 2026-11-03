#import "SFKodiImport.h"
#import "SFLibrary.h"
#import "SFStore.h"
#import <sqlite3.h>

void SFKodiImportIfNeeded(void) {
    if ([[SFStore shared] setting:@"kodi.imported"]) return;
    [[SFLibrary shared] whenReady:^{
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Kodi/userdata/Database"];
        NSString *db = nil;
        for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil])
            if ([f hasPrefix:@"MyVideos"] && [f hasSuffix:@".db"] && (!db || [f compare:db options:NSNumericSearch] == NSOrderedDescending)) db = f;
        if (!db) { [[SFStore shared] setSetting:@"none" forKey:@"kodi.imported"]; return; }
        NSString *path = [dir stringByAppendingPathComponent:db];
        NSString *root = [[SFLibrary shared].root stringByAppendingString:@"/"].precomposedStringWithCanonicalMapping;
        sqlite3 *h;
        if (sqlite3_open_v2(path.fileSystemRepresentation, &h, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) return;
        const char *sql = "SELECT p.strPath||f.strFilename, f.playCount, b.timeInSeconds, b.totalTimeInSeconds "
                          "FROM files f JOIN path p USING(idPath) LEFT JOIN bookmark b ON b.idFile=f.idFile AND b.type=1 "
                          "WHERE f.playCount>0 OR b.timeInSeconds>0";
        sqlite3_stmt *st;
        NSUInteger watched = 0, resumed = 0;
        if (sqlite3_prepare_v2(h, sql, -1, &st, NULL) == SQLITE_OK) {
            while (sqlite3_step(st) == SQLITE_ROW) {
                const char *p = (const char *)sqlite3_column_text(st, 0);
                if (!p) continue;
                NSString *fp = @(p).precomposedStringWithCanonicalMapping;
                if (![fp hasPrefix:root]) continue;
                SFItem *it = [[SFLibrary shared] episodeForPath:fp];
                if (!it) continue;
                int plays = sqlite3_column_int(st, 1);
                double pos = sqlite3_column_double(st, 2), dur = sqlite3_column_double(st, 3);
                if (pos > 0 && dur > 0) { [[SFStore shared] savePosition:pos duration:dur forItem:it]; resumed++; }
                else if (plays > 0) { [[SFStore shared] setWatched:YES forItem:it]; watched++; }
            }
            sqlite3_finalize(st);
        }
        sqlite3_close(h);
        SFLog(@"kodi-import: %lu gesehen, %lu fortsetzbar aus %@", (unsigned long)watched, (unsigned long)resumed, db);
        [[SFStore shared] setSetting:[NSString stringWithFormat:@"%lu/%lu", (unsigned long)watched, (unsigned long)resumed] forKey:@"kodi.imported"];
        [[NSNotificationCenter defaultCenter] postNotificationName:SFLibraryDidChangeNotification object:nil];
    }];
}
