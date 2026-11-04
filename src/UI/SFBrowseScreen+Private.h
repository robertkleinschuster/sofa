// SFBrowseScreen – privater Teil: Ivars und Zeilenmodell, gemeinsam für SFBrowseScreen.m
// (Layout, Zeilen, Fokus, Hero) und SFBrowseScreen+Context.m (Kontextmenü „OK halten“).
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

// Ein sichtbarer "Zeilen"-Abschnitt: Rail = eine Zeile; Grid = mehrere Zeilen.
@interface SFRow : NSObject
@property (nonatomic) NSUInteger shelf;
@property (nonatomic, strong) NSArray *items;        // Items dieser Zeile
@property (nonatomic) NSUInteger firstIndex;         // Index im Shelf
@property (nonatomic) SFTileStyle style;
@property (nonatomic) BOOL rail;
@property (nonatomic, copy) NSString *title;         // nur erste Zeile eines Shelfs
@property (nonatomic) CGFloat y, height, titleHeight;
@property (nonatomic) NSInteger focusCol;            // letzter Fokus in der Zeile
@property (nonatomic) NSInteger scrollCol;           // erste sichtbare Spalte (Rail)
@property (nonatomic, strong) CALayer *layer;        // Zeilencontainer
@property (nonatomic, strong) CALayer *strip;        // verschiebbarer Kachelstreifen
@property (nonatomic, strong) NSMutableDictionary *tiles; // @(col) -> SFTileLayer
@property (nonatomic, strong) NSArray *widths;       // content-sized button pills: width per column (points), else nil
@end

@interface SFBrowseScreen () {
    SFPage *_page;
    BOOL _pinTop;   // Startfokus unterhalb der ersten Reihe: nicht scrollen, solange die Zeile sichtbar ist
    CALayer *_bg;
    SFImageLayer *_backdrop;
    CALayer *_backdropBox;
    CAGradientLayer *_backdropFade, *_backdropFadeBottom;
    CALayer *_header;
    SFLabel *_wordmark, *_pageTitle, *_clock, *_hint, *_phone;
    NSTimer *_prefetchTimer;      // YouTube vorladen bei ruhendem Fokus
    CALayer *_hintKey, *_phonePill, *_phoneDot;   // Statuszeile oben rechts
    CALayer *_searchPill; CAShapeLayer *_searchIcon; SFLabel *_searchLabel;   // Kopfzeile: „Suche“
    BOOL _headerFocus;           // Fokus liegt auf „Suche“ statt auf einer Kachel
    CALayer *_content;           // vertikal verschobener Inhalt
    NSMutableArray *_rows;
    NSInteger _row;              // fokussierte Zeile
    CGFloat _contentTop;         // y-Beginn der Shelves
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
