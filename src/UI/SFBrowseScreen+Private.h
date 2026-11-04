// SFBrowseScreen – private part: ivars and row model, shared by SFBrowseScreen.m
// (layout, rows, focus, hero) and SFBrowseScreen+Context.m (context menu "hold OK").
#import "SFBrowseScreen.h"
#import "SFTile.h"
#import "SFLayers.h"
#import "SFStore.h"
#import "SFMenuScreen.h"
#import "SFDownloads.h"
#import "SFNet.h"
#import "SFLounge.h"
#import "SFFollows.h"
#import "SFYTResolver.h"
#import "SFLibrary.h"
#import "SFPlayerScreen.h"
#import "SFHome.h"
#import "SFLogo.h"
#import "SFSearch.h"
#import "SFWatchLater.h"

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
    SFPage *_page;
    BOOL _pinTop;   // start focus below the first row: do not scroll while the row is visible
    CALayer *_bg;
    SFImageLayer *_backdrop;
    CALayer *_backdropBox;
    CAGradientLayer *_backdropFade, *_backdropFadeBottom;
    CALayer *_header;
    SFLabel *_wordmark, *_pageTitle, *_clock, *_hint, *_phone;
    NSTimer *_prefetchTimer;      // preload YouTube while focus rests
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

@interface SFBrowseScreen (Context)
- (void)showContextMenuFor:(SFItem *)it shelfItems:(NSArray *)items index:(NSUInteger)idx;
@end
