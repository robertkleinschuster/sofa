// On-screen keyboard for the 7-key remote: letter grid, text line at the top,
// suggestion list on the right. Generic (search, later other text input).
//   arrows = focus, centre = key/suggestion, Play/Pause = delete character,
//   centre long = clear all (on a suggestion: take it into the text line),
//   right long = to "Suchen", left long = to the grid start, MENU = cancel.
#import "SFScreen.h"

// Suggestions (NSString) with heading ("Vorschläge", "Zuletzt gesucht").
typedef void (^SFSuggestDone)(NSString *heading, NSArray *suggestions);
typedef void (^SFSuggestProvider)(NSString *text, SFSuggestDone done);

@interface SFKeyboardScreen : SFScreen
// completion gets the trimmed, non-empty text. The keyboard stays on the
// stack (the caller pushes e.g. the results on top; MENU there = refine the search).
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
