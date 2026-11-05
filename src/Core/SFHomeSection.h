// A section (shelf) of Sofa's home page. The shell composes the page from its own sections and
// the apps' contributions (SFApp homeSections), ordered by priority, stable inside a band:
//   0 app tiles · 100 Weiterschauen · 200 Später ansehen · 300 Neue Folgen ·
//   310 Jetzt live · 320 Highlights (both mixed from all apps, SFHomeFeatures) ·
//   400 Meine Sendungen · 500+ app sections (e.g. YouTube "Meine Kanäle")
#import "SFModel.h"

enum {
    SFHomePriorityApps = 0, SFHomePriorityContinue = 100, SFHomePriorityWatchLater = 200,
    SFHomePriorityNew = 300, SFHomePriorityLive = 310, SFHomePriorityHighlights = 320,
    SFHomePriorityFollows = 400, SFHomePriorityApp = 500
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
