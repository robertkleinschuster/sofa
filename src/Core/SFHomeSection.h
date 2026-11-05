// A section (shelf) of Sofa's home page. The shell composes the page from its own sections and
// the apps' contributions (SFApp homeSections), ordered by priority, stable inside a band.
// The page reads top down from "mine" to "discover" (user 2026-11-05: Weiterschauen stays first):
//   100 Weiterschauen · 200 Neue Folgen  - what I am watching / follow
//   300 app tiles (+ Downloads, Verlauf, Einstellungen) - two presses away, divides mine and discover
//   400 Jetzt live · 500 Nachrichten · 600 Highlights - mixed from all apps (SFHomeFeatures)
//   700 Später ansehen · 800 Meine Sendungen · 900+ app sections (e.g. YouTube "Meine Kanäle")
#import "SFModel.h"

enum {
    SFHomePriorityContinue = 100, SFHomePriorityNew = 200, SFHomePriorityApps = 300,
    SFHomePriorityLive = 400, SFHomePriorityNews = 500, SFHomePriorityHighlights = 600,
    SFHomePriorityWatchLater = 700, SFHomePriorityFollows = 800, SFHomePriorityApp = 900
};

@interface SFHomeSection : NSObject
@property (nonatomic, copy) NSString *identifier;   // stable id ("youtube.channels")
@property (nonatomic, copy) NSString *title;        // nil = no heading (app tiles)
@property (nonatomic) NSInteger priority;
@property (nonatomic) SFTileStyle style;
@property (nonatomic) BOOL grid;                    // grid instead of one row
// items when the page is built (main thread, library ready); empty = section hidden
@property (nonatomic, copy) NSArray *(^items)(void);
+ (instancetype)section:(NSString *)identifier title:(NSString *)title priority:(NSInteger)priority
                  style:(SFTileStyle)style items:(NSArray *(^)(void))items;
- (SFShelf *)makeShelf;   // nil when empty
// sections sorted by priority (stable) -> shelves of the non-empty ones
+ (NSArray *)shelvesFrom:(NSArray *)sections;
@end
