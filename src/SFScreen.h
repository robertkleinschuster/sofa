// Bildschirm-Basisklasse und Navigator (Stapel, Übergänge, Eingabe-Verteilung).
#import "SFCore.h"
#import "SFTheme.h"

@class SFNavigator;

@interface SFScreen : NSObject
@property (nonatomic, strong, readonly) CALayer *layer;   // Wurzel (Bildschirmgröße)
@property (nonatomic, weak) SFNavigator *navigator;
@property (nonatomic, strong) SFTheme *theme;
@property (nonatomic, readonly) CGSize size;
@property (nonatomic, copy) NSString *restoreKey;     // z.B. "app:zdf" (Wiederherstellung nach Update)
- (instancetype)initWithTheme:(SFTheme *)theme;
- (void)layoutForSize:(CGSize)size;   // einmalig vor dem Erscheinen + bei Größenänderung
- (void)willAppear;
- (void)didAppear;
- (void)willDisappear;
- (BOOL)handleKey:(SFKey)key;         // NO = Navigator übernimmt (Menu = zurück)
- (BOOL)wantsCursorHidden;
- (BOOL)isOpaque;                     // NO = darunterliegender Screen bleibt sichtbar (Dialoge)
@end

@interface SFNavigator : NSView
@property (nonatomic, readonly) NSArray *stack;
@property (nonatomic, readonly) SFScreen *top;
- (void)push:(SFScreen *)s;
- (void)pop;
- (void)popToRoot;
- (void)replaceTop:(SFScreen *)s;
- (void)sendKey:(SFKey)key;
// Kurze Einblendung unten (Hinweise, Fehler)
- (void)toast:(NSString *)text;
// Lautstärke ändern (dir ±1) und Anzeige einblenden
- (void)volumeStep:(int)dir;
// MENU auf dem untersten Screen (Home): Energie-Menü statt nichts
@property (nonatomic, copy) dispatch_block_t rootMenuHandler;
@end

NSCursor *SFBlankCursor(void);   // transparenter Mauszeiger (TV-Oberfläche)
