#import "SFFollowAction.h"
#import "SFFollows.h"
#import "SFDownloads.h"
#import "SFMenuScreen.h"
#import "SFApp.h"

void SFToggleFollow(SFNavigator *nav, SFItem *folder, SFTheme *theme, BOOL askAlways) {
    SFFollows *fo = [SFFollows shared];
    NSString *fid = folder.identifier, *title = folder.title.length ? folder.title : @"Sendung";
    if (!nav || !fid) return;
    BOOL channel = SFShowRefIsChannel(fid);
    NSString *news = channel ? @"Videos" : @"Folgen";
    if (![fo isFollowing:fid]) {
        [fo follow:folder];
        [nav toast:[NSString stringWithFormat:@"Du folgst „%@“ – neue %@ erscheinen unter „Neue Folgen“", title, news]];
        return;
    }
    BOOL autoDL = [[SFDownloads shared] isSubscribed:fid];
    dispatch_block_t unfollow = ^{
        [fo unfollow:fid];   // also ends "Automatisch herunterladen"
        [nav toast:[NSString stringWithFormat:@"Du folgst „%@“ nicht mehr", title]];
    };
    if (!autoDL && !askAlways) { unfollow(); return; }
    SFMenuOption *no = [SFMenuOption option:@"Abbrechen" action:^{}];
    SFMenuOption *yes = [SFMenuOption option:@"Nicht mehr folgen" action:unfollow];
    NSString *sub = autoDL ? [NSString stringWithFormat:@"Neue %@ erscheinen nicht mehr unter „Neue Folgen“ und werden nicht mehr geladen. Vorhandene Downloads bleiben.", news]
                           : [NSString stringWithFormat:@"Neue %@ erscheinen dann nicht mehr unter „Neue Folgen“.", news];
    // after the current key event (the button's action runs inside it)
    dispatch_async(dispatch_get_main_queue(), ^{
        [nav push:[[SFMenuScreen alloc] initWithTitle:[NSString stringWithFormat:@"„%@“ nicht mehr folgen?", title]
                                             subtitle:sub options:@[no, yes] theme:theme]];
    });
}
