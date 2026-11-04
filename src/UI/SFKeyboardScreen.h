// Bildschirmtastatur für die 7-Tasten-Fernbedienung: Buchstabenraster, Textzeile oben,
// Vorschlagsliste rechts. Generisch (Suche, später andere Texteingaben).
//   Pfeile = Fokus, Mitte = Taste/Vorschlag, Play/Pause = Zeichen löschen,
//   Mitte lang = alles löschen (auf Vorschlag: in die Textzeile übernehmen),
//   Rechts lang = zu „Suchen“, Links lang = zum Rasteranfang, MENU = abbrechen.
#import "SFScreen.h"

// Vorschläge (NSString) samt Überschrift ("Vorschläge", "Zuletzt gesucht").
typedef void (^SFSuggestDone)(NSString *heading, NSArray *suggestions);
typedef void (^SFSuggestProvider)(NSString *text, SFSuggestDone done);

@interface SFKeyboardScreen : SFScreen
// completion bekommt den getrimmten, nicht-leeren Text. Die Tastatur bleibt auf dem
// Stapel (der Aufrufer pusht z.B. die Ergebnisse darüber; MENU dort = Suche verfeinern).
- (instancetype)initWithTitle:(NSString *)title theme:(SFTheme *)theme initialText:(NSString *)text
                   completion:(void (^)(NSString *text))completion;
@property (nonatomic, copy) NSString *placeholder;           // Default "Suchbegriff eingeben"
@property (nonatomic, copy) NSString *submitTitle;           // Default "Suchen"
@property (nonatomic, copy) SFSuggestProvider suggestionProvider;
@property (nonatomic, copy) dispatch_block_t onCancel;       // MENU
@property (nonatomic, readonly) NSString *text;
- (void)setText:(NSString *)text;
- (void)refreshSuggestions;
@end
