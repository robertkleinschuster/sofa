// SFBrowseScreen – private part: ivars and row model, shared by SFBrowseScreen.m (layout, page,
// rows) and its parts +Header, +Focus, +Hero, +Context (context menu "hold OK").
#import "SFBrowseScreen.h"
#import "SFTile.h"
#import "SFLayers.h"
#import "SFStore.h"
#import "SFMenuScreen.h"
#import "SFDownloads.h"
#import "SFNet.h"
#import "SFFollows.h"
#import "SFLibrary.h"
#import "SFPlayerScreen.h"
#import "SFLogo.h"
#import "SFSearch.h"
#import "SFWatchLater.h"
#import "SFApp.h"
#import "SFLibraryPages.h"

// A visible "row" section: rail = one row; grid = several rows.
@interface SFRow : NSObject
@property (nonatomic) NSUInteger shelf;
@property (nonatomic, strong) NSArray *items;        // items of this row
@property (nonatomic) NSUInteger firstIndex;         // index in the shelf
@property (nonatomic) SFTileStyle style;
@property (nonatomic) BOOL rail;
@property (nonatomic, copy) NSString *title;         // only the first row of a shelf
@property (nonatomic) CGFloat y, height, titleHeight;
@property (nonatomic) NSInteger focusCol;            // last focus in the row
@property (nonatomic) NSInteger scrollCol;           // first visible column (rail)
@property (nonatomic, strong) CALayer *layer;        // row container
@property (nonatomic, strong) CALayer *strip;        // movable strip of tiles
@property (nonatomic, strong) NSMutableDictionary *tiles; // @(col) -> SFTileLayer
@property (nonatomic, strong) NSArray *widths;       // content-sized button pills: width per column (points), else nil
@end

@interface SFBrowseScreen () {
    BOOL _reloadPending;          // a coalesced notification reload is queued
    NSUInteger _reloadSeq;        // the newest reload: an older one answering later is dropped
    BOOL _loadFailed;             // the page shows a load error (OK and coming online retry)
    SFPage *_page;
    BOOL _pinTop;   // start focus below the first row: do not scroll while the row is visible
    CALayer *_bg;
    SFImageLayer *_backdrop;
    CALayer *_backdropBox;
    CAGradientLayer *_backdropFade, *_backdropFadeBottom;
    CALayer *_header;
    SFLabel *_wordmark, *_pageTitle, *_clock, *_hint, *_phone;
    NSTimer *_prefetchTimer;      // app preload (preloadOnFocus:) while focus rests
    NSString *_prefetchedID;      // the item last preloaded: a page rebuild that keeps the focus does not preload it again
    CALayer *_hintKey, *_phonePill, *_phoneDot;   // status line top right
    CALayer *_searchPill; CAShapeLayer *_searchIcon; SFLabel *_searchLabel;   // header: "Suche"
    BOOL _headerFocus;           // focus is on "Suche" instead of a tile
    CALayer *_content;           // vertically shifted content
    NSMutableArray *_rows;
    NSInteger _row;              // focused row
    CGFloat _contentTop;         // y start of the shelves
    CGFloat _scrollY;
    // Hero
    CALayer *_hero;
    SFLabel *_heroTitle, *_heroMeta, *_heroPlot;
    NSUInteger _heroSeq;
    // Status
    CALayer *_spinner;
    SFLabel *_empty;
    NSTimer *_clockTimer;
    BOOL _loading, _laidOut;
}
@end

// methods shared between SFBrowseScreen.m and its parts (+Header, +Focus, +Hero, +Context)
@interface SFBrowseScreen (Internal)
- (void)observeDownloads;
- (SFPage *)page;
- (BOOL)isOpaque;
- (void)setReloadNotification:(NSString *)name;
- (void)layoutForSize:(CGSize)size;
- (void)buildHeader:(CGSize)size;
- (void)layoutStatusRow;
- (void)schedulePrefetch;
- (void)prefetchFocused;
- (void)updatePhoneStatus;
- (void)updateHint;
- (void)updateClock;
- (void)willAppear;
- (void)willDisappear;
- (void)didAppear;
- (void)reloadSoon;
- (NSString *)shelfTitleForRow:(SFRow *)r;
- (void)showSpinner:(BOOL)on;
- (void)buildRows;
- (void)materializeRow:(SFRow *)r;
- (CGFloat)xForCol:(NSInteger)c inRow:(SFRow *)r;
- (CGFloat)widthForCol:(NSInteger)c inRow:(SFRow *)r;
- (CGFloat)scrollOffsetForRow:(SFRow *)r col:(NSInteger)sc;
- (NSInteger)scrollColForRow:(SFRow *)r col:(NSInteger)col;
- (void)updateTilesInRow:(SFRow *)r;
- (void)updateVisibleRows;
- (void)focusRow:(NSInteger)row col:(NSInteger)col animated:(BOOL)anim;
- (void)updateSearchPill:(BOOL)anim;
- (void)focusHeaderSearch;
- (BOOL)handleKey:(SFKey)key;
- (void)bump:(NSInteger)dir;
- (void)updateBackdropFor:(SFItem *)it;
- (void)buildHero:(CGSize)size;
- (void)updateHeroFor:(SFItem *)it;
@end

@interface SFBrowseScreen (Context)
- (void)showContextMenuFor:(SFItem *)it shelfItems:(NSArray *)items index:(NSUInteger)idx;
- (void)downloadChanged:(NSNotification *)n;   // SFDownloadsDidChangeNotification: that item's tiles
@end
