// SFDownloads (Integrity) - a download is its item's tracks in the media store; the store keeps its
// index true against its block files (SFMediaStore checkBlocks), and here every finished download is
// checked for completeness once per launch: one that lost bytes (block files deleted from outside) is
// queued again and its fill fetches only what is missing. (The file downloads' layers - orphaned
// ffmpeg processes, part files, a verifier, an audit - went with the files, 2026-11-08.)
#import "SFDownloads+Private.h"
#import "SFMediaStore.h"

@implementation SFDownloads (Integrity)

- (void)verifyStoreDownloads {
    NSMutableArray *ids = [NSMutableArray new];
    for (SFDownloadRecord *r in _recs.allValues) if (r.state == SFDLDone) [ids addObject:r.identifier];
    if (!ids.count) return;
    SFMediaStore *store = self.mediaStore;
    SFBackground(^{   // waits for the store's block check (a cold disk: seconds) - never on the main thread
        NSMutableArray *incomplete = [NSMutableArray new];
        for (NSString *ident in ids) if (![store itemIsComplete:ident]) [incomplete addObject:ident];
        SFMain(^{
            NSMutableArray *writes = [NSMutableArray new];
            for (NSString *ident in incomplete) {
                SFDownloadRecord *r = self->_recs[ident];
                if (r.state != SFDLDone) continue;
                SFLog(@"downloads: %@ is incomplete in the media store - loading the rest", ident);
                r.state = SFDLQueued; r.progress = 0; r.error = nil; r.tries = 0; r.retryAt = 0;
                [writes addObject:[self write:r]];
                [self changed:ident];
            }
            if (writes.count) { [[SFStore shared] runAll:writes]; [self pump]; }
        });
    });
}

@end
