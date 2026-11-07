// SFPlayerInfoScreen - the action buttons of the info panel and their order.
#import "SFPlayerInfoScreen+Private.h"
#import "SFDownloads.h"
#import "SFFollows.h"
#import "SFWatchLater.h"
#import "SFFollowAction.h"

@implementation SFPlayerInfoScreen (Actions)

- (SFItem *)button:(NSString *)ident title:(NSString *)title hero:(SFItem *)hero action:(dispatch_block_t)action {
    SFItem *b = [SFItem new];
    b.kind = SFItemAction; b.style = SFTileStyleButton;
    b.identifier = [@"info:" stringByAppendingString:ident];
    b.title = title;
    b.heroTitle = hero.heroTitle; b.heroMeta = hero.heroMeta; b.plot = hero.plot;   // hero keeps showing the video
    b.action = action;
    return b;
}

// The order: what is known at once first (online stream, download, watch later), what needs the
// app's details or the engine's tracks after it (show, follow, audio, subtitles). A button keeps
// the place it appeared at; one that comes later is appended - never inserted before what is
// shown (user 2026-11-07: the row shifted while the panel loaded).
- (NSArray *)stableOrder:(NSArray *)actions {
    static NSArray *preferred;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ preferred = @[@"info:online", @"info:download", @"info:later", @"info:show", @"info:follow",
                                          @"info:audio", @"info:sub", @"info:back"]; });
    NSUInteger (^rank)(SFItem *) = ^NSUInteger(SFItem *b) { NSUInteger r = [preferred indexOfObject:b.identifier]; return r == NSNotFound ? preferred.count : r; };
    NSArray *byRank = [actions sortedArrayUsingComparator:^NSComparisonResult(SFItem *x, SFItem *y) { return [@(rank(x)) compare:@(rank(y))]; }];
    if (!_actionOrder) _actionOrder = [NSMutableArray new];
    for (SFItem *b in byRank) if (![_actionOrder containsObject:b.identifier]) [_actionOrder addObject:b.identifier];
    return [byRank sortedArrayUsingComparator:^NSComparisonResult(SFItem *x, SFItem *y) {
        return [@([self->_actionOrder indexOfObject:x.identifier]) compare:@([self->_actionOrder indexOfObject:y.identifier])];
    }];
}

- (NSArray *)actionsWithHero:(SFItem *)hero {
    SFPlayerScreen *p = _player;
    SFItem *it = [self enrichedItem];
    __weak SFNavigator *nav = self.navigator;   // blocks live in the page: no strong path back to the navigator
    __weak SFPlayerInfoScreen *ws = self;
    __weak SFPlayerScreen *wp = p;
    NSMutableArray *a = [NSMutableArray new];
    BOOL live = it.kind == SFItemLive;

    // Audio / subtitles (only when there is a choice); the choices are taken fresh when chosen
    if ([p tracksAvailable]) {
        for (NSString *type in @[@"audio", @"sub"]) {
            NSArray *choices = [p trackChoices:type];
            if (choices.count < 2) continue;
            BOOL audio = [type isEqualToString:@"audio"];
            NSString *name = audio ? @"Ton" : @"Untertitel";
            [a addObject:[self button:type title:[NSString stringWithFormat:@"%@: %@", name, [p currentChoice:choices]] hero:hero action:^{
                SFPlayerScreen *pl = wp;
                if (![pl tracksAvailable]) return;
                NSArray *c = [pl trackChoices:type];
                if (c.count) [pl showChoices:c type:type title:name on:ws.navigator ?: nav];
            }]];
        }
    }
    // Downloaded file: online there are all audio and subtitle tracks
    if ([p canSwitchToStream]) {
        [a addObject:[self button:@"online" title:@"Online abspielen" hero:hero action:^{ [wp switchToStream]; }]];
    }
    // Channel / show page; leaving the video for it replaces the player (progress is saved)
    SFShowLink *link = [SFShowLink linkFor:it here:nil pageTitle:nil];
    if (link) {
        [a addObject:[self button:@"show" title:link.title hero:hero action:^{
            SFNavigator *n = ws.navigator ?: nav;
            [link openOn:n stillValid:^BOOL { return ws && n.top == ws; } present:^(SFScreen *screen) {
                SFPlayerScreen *pl = wp;
                if (pl && [n.stack containsObject:pl]) { [n popAbove:pl]; [n replaceTop:screen]; }
                else [n push:screen];
            }];
        }]];
    }
    // Follow the channel / show (needs its identifier; YouTube: known once the watch page arrived)
    SFItem *folder = [link.folder copy];
    SFFollows *fo = [SFFollows shared];
    if (folder && [fo canFollow:folder]) {
        if (!folder.image.length && _details[@"avatar"]) folder.image = _details[@"avatar"];
        BOOL following = [fo isFollowing:folder.identifier];
        SFItem *b = [self button:@"follow" title:following ? @"✓  Gefolgt" : @"Folgen" hero:hero action:^{
            SFToggleFollow(ws.navigator ?: nav, folder, ws.theme, NO);
        }];
        if (!following) b.tint = self.theme.accent;
        [a addObject:b];
    }
    // Download state of this video (offline layer)
    if (!live && !it.drm && it.identifier) {
        SFDownloads *dl = [SFDownloads shared];
        double dp = 0;
        SFDLState ds = [dl stateFor:it.identifier progress:&dp];
        NSString *ident = it.identifier;
        if (ds == SFDLQueued || ds == SFDLRunning) {
            NSString *t = ds == SFDLRunning ? [NSString stringWithFormat:@"Download abbrechen (%d %%)", (int)round(dp * 100)] : @"Download abbrechen (wartet)";
            [a addObject:[self button:@"download" title:t hero:hero action:^{
                [dl remove:ident];
                [(ws.navigator ?: nav) toast:@"Download abgebrochen"];
            }]];
        } else if (ds == SFDLDone) {
            [a addObject:[self button:@"download" title:@"Download löschen" hero:hero action:^{
                SFNavigator *n = ws.navigator ?: nav;
                // Destructive and possibly the very file that is playing: ask, naming the video - and
                // say so when the copy is irreplaceable (kept, or no longer online), as the context menu does
                BOOL kept = [dl isKept:ident], gone = [dl onlineStateFor:ident] == 0;
                SFMenuOption *no = [SFMenuOption option:@"Abbrechen" action:^{}];
                SFMenuOption *yes = [SFMenuOption option:kept || gone ? @"Ja, endgültig löschen" : @"Ja, Download löschen" action:^{
                    [dl remove:ident];
                    [n toast:kept || gone ? @"Download gelöscht" : @"Download gelöscht – das Video bleibt online verfügbar"];
                }];
                NSString *sub = gone ? [NSString stringWithFormat:@"„%@“ ist nicht mehr online – die Kopie hier ist die einzige.", it.title]
                              : kept ? [NSString stringWithFormat:@"„%@“ ist als „Behalten“ markiert.", it.title] : it.title;
                SFMenuScreen *m = [[SFMenuScreen alloc] initWithTitle:@"Download löschen?" subtitle:sub options:@[no, yes] theme:ws.theme];
                m.subtitleLines = 4;
                [n push:m];
            }]];
        } else if (it.resolverRef || it.resolver) {
            SFItem *dlItem = [it copy];
            dlItem.streamOnly = NO;
            [a addObject:[self button:@"download" title:@"Herunterladen" hero:hero action:^{
                [dl download:dlItem];
                [(ws.navigator ?: nav) toast:@"Wird heruntergeladen – auch offline verfügbar"];
            }]];
        }
    }
    // Shared watch-later list
    if (!live && !it.drm && it.identifier && it.kind == SFItemVideo) {
        SFWatchLater *wl = [SFWatchLater shared];
        BOOL in = [wl contains:it.identifier];
        SFItem *wlItem = [it copy];
        wlItem.streamOnly = NO;
        NSString *ident = it.identifier;
        [a addObject:[self button:@"later" title:in ? @"✓  Später ansehen" : @"Später ansehen" hero:hero action:^{
            SFNavigator *n = ws.navigator ?: nav;
            if ([wl contains:ident]) { [wl remove:ident]; [n toast:@"Aus „Später ansehen“ entfernt"]; }
            else { [wl add:wlItem]; [n toast:@"Gemerkt – steht unter „Später ansehen“"]; }
            [ws refresh];
        }]];
    }
    // Never an empty panel: MENU is the way back, but a visible button teaches it
    if (!a.count) [a addObject:[self button:@"back" title:@"Zurück zum Video" hero:hero action:^{ [ws leave]; }]];
    return [self stableOrder:a];
}
@end
