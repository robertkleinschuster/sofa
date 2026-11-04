// Nutzer-Einstellungen (macOS-Preferences, auch vom Helper SofaRemote lesbar).
// Domain de.sofa.app (Dev-Instanzen: de.sofa.dev, nie die echte App beeinflussen).
//
// REGEL: Hier steht, was der Nutzer bewusst wählt (Einstellungsmenü, Rückfragen, Schalter in
// Bildschirmen). Zustand, den Sofa selbst führt (Handy-Kopplung, letzte Suchen, zuletzt benutztes
// Tastatur-Layout, Migrations-Marker, Zeitstempel), gehört in SFStore (-setting:/-setSetting:).
#import <Foundation/Foundation.h>

BOOL SFAutostartEnabled(void);            // beim Anmelden starten (Standard: an)
void SFSetAutostartEnabled(BOOL on);
BOOL SFRemoteLaunchEnabled(void);         // geschlossenes Sofa mit jeder Taste der Apple Remote starten (Standard: an)
void SFSetRemoteLaunchEnabled(BOOL on);
BOOL SFAutoUpdateEnabled(void);           // Updates von GitHub automatisch laden + in Ruhe installieren (Standard: an)
void SFSetAutoUpdateEnabled(BOOL on);
BOOL SFStartupQuestionsAsked(void);       // Ersteinrichtung hat beides abgefragt
void SFSetStartupQuestionsAsked(void);
// mpv ist der Standard-Player; YES = alte Wahl (H.264 über AVFoundation). Nur per defaults, Notschalter.
BOOL SFPreferAVFoundation(void);
// Gesehene Abo-Folgen einen Tag nach dem Ansehen löschen (Standard: an)
BOOL SFDeleteWatchedDownloads(void);
void SFSetDeleteWatchedDownloads(BOOL on);
// Bevorzugte Untertitelsprache (z.B. "de"); nil = Untertitel aus (Standard). Wird bei jeder
// Auswahl im Player gemerkt und beim nächsten Video angewandt, wenn die Sprache verfügbar ist.
NSString *SFSubtitleLanguage(void);
void SFSetSubtitleLanguage(NSString *lang);
// Untertitel auch bei gleicher Sprache wie der Ton (Hörgeschädigten-Untertitel); subtitleLanguage
// gilt dagegen nur für fremdsprachigen Ton (Übersetzung).
BOOL SFSubtitlesSameLanguage(void);
void SFSetSubtitlesSameLanguage(BOOL on);
