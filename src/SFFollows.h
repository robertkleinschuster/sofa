// „Folgen“: Kanäle/Sendungen, die der Haushalt verfolgt – über alle Apps, ohne Anmeldung, gemeinsam.
// Kern des Konzepts (NOTES „Folgen statt Download-Abos“): Gefolgte Sendungen liefern „Neue Folgen“
// (gestreamt) und „Meine Sendungen & Kanäle“. „Automatisch herunterladen“ (SFDownloads-Abo) ist nur
// ein optionaler Zusatz pro gefolgter Sendung und setzt Folgen voraus.
// Neue Folgen werden im Hintergrund (alle 30 min, nacheinander) geholt und gecacht, damit Home sofort
// erscheint – nicht 128 Anfragen bei jedem Öffnen.
#import "SFModel.h"

extern NSString *const SFFollowsDidChangeNotification;

// Seite einer Sendung/eines Kanals aus seiner Kennung bauen (je Provider registriert)
typedef SFPageLoader (^SFShowPageFactory)(NSString *ref, NSString *title);
void SFRegisterShowPage(NSString *prefix, SFShowPageFactory f);
SFPageLoader SFShowPageLoader(NSString *ref, NSString *title);   // nil, wenn für den Typ keine Seite registriert ist
// Sendung/Kanal einer Folge nachträglich ermitteln (Items ohne showRef, z. B. ältere gespeicherte)
typedef void (^SFShowRefLookup)(SFItem *item, void (^done)(NSString *ref));
void SFRegisterShowRefLookup(NSString *source, SFShowRefLookup f);
SFShowRefLookup SFShowRefLookupFor(NSString *source);

@interface SFFollows : NSObject
+ (instancetype)shared;
- (void)start;                                         // Migration + Hintergrund-Aktualisierung
- (BOOL)canFollow:(SFItem *)folder;                    // gibt es Feed + Seite für diesen Typ?
- (BOOL)isFollowing:(NSString *)identifier;
- (void)follow:(SFItem *)folder;
- (void)unfollow:(NSString *)identifier;               // beendet auch „Automatisch herunterladen“
- (NSArray *)follows:(NSString *)source;               // SFItem-Ordner (alphabetisch), nil = alle
- (NSArray *)latest:(NSInteger)n source:(NSString *)source;   // neueste Folgen gefolgter Sendungen
- (void)refreshNow;
- (void)importFollows:(NSArray *)folders key:(NSString *)onceKey;   // einmaliger Import (z. B. YouTube-Konto)
@end
