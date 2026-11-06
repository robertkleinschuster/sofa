// Opening an item from any screen: a video/live plays, a folder becomes a browse screen, an action runs.
#import "SFBrowseScreen+Private.h"

SFBrowseScreen *SFBrowseScreenForFolder(SFItem *item, SFTheme *fallback) {
    SFTheme *t = [SFTheme themeNamed:item.themeName ?: fallback.identifier ?: @"home"];
    SFBrowseScreen *b = [[SFBrowseScreen alloc] initWithLoader:item.pageLoader theme:t];
    b.folderIdentifier = item.identifier;
    // offline pages (show, downloads) follow the inventory live
    BOOL channel = [SFAppRegistry isShowRef:item.identifier] && SFShowRefIsChannel(item.identifier);   // shows its downloaded videos too
    if ([item.identifier hasPrefix:@"show:"] || [item.identifier hasPrefix:@"downloads:"] || channel) b.reloadNotification = SFLibraryDidChangeNotification;
    if ([item.identifier hasPrefix:@"room:"]) b.reloadNotification = SFDownloadsStorageDidChangeNotification;   // deletions, online checks
    if (channel) b.showsHero = YES;   // channel header (banner, subscribers, description)
    return b;
}

void SFOpenItem(SFNavigator *nav, SFItem *item, NSArray *queue, NSUInteger index) {
    // copy-protected: say so honestly right away instead of spinner + error screen
    if (item.drm && (item.kind == SFItemVideo || item.kind == SFItemLive)) { [nav toast:SFDRMNotice]; return; }
    switch (item.kind) {
        case SFItemVideo:
        case SFItemLive: {
            SFPlayerScreen *p = [[SFPlayerScreen alloc] initWithItem:item queue:queue index:index];
            [nav push:p];
            break;
        }
        case SFItemFolder:
            [nav push:SFBrowseScreenForFolder(item, nav.top.theme)];
            break;
        case SFItemAction:
            if (item.action) item.action();
            break;
    }
}
