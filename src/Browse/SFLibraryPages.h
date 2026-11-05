// Library pages (app-agnostic): local shows, history, downloads, "Platz schaffen", and the
// followed-shows frame of an app start page. Used by the home screen, apps and context menus.
#import "SFBrowseScreen.h"
#import "SFLibrary.h"

@interface SFLibraryPages : NSObject
+ (void)reloadOnLibraryChange:(SFBrowseScreen *)s;              // keep downloads/follows shelves current
+ (SFItem *)showTile:(SFShow *)sh;                              // tile of a local show (opens showLoader:source:)
+ (SFPageLoader)showLoader:(NSString *)showName source:(NSString *)source;   // local show
+ (SFItem *)historyTile;                                        // opens the history
// app start page + Neue Folgen / Meine Sendungen (followed shows) + downloads tile of this app
+ (SFPageLoader)withLocalShows:(SFPageLoader)online source:(NSString *)source;
@end

// Downloads page – SFLibraryPages+Downloads.m
@interface SFLibraryPages (Downloads)
+ (SFPageLoader)downloadsLoader:(NSString *)source;           // nil = all sources
+ (SFItem *)downloadsTile:(NSString *)source;                  // opens the downloads page
+ (SFItem *)roomTile;                                          // opens "Platz schaffen" (bulk deleting, by hand)
+ (void)watchStorage;                                          // ask to make room when the disk becomes full
@end
