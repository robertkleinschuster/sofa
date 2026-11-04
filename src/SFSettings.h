// Start-Einstellungen, die auch der Helper (SofaRemote) liest: macOS-Preferences statt SQLite.
// Domain de.sofa.app (Dev-Instanzen: de.sofa.dev, nie die echte App beeinflussen).
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
// Bevorzugte Untertitelsprache (z.B. "de"); nil = Untertitel aus (Standard). Wird bei jeder
// Auswahl im Player gemerkt und beim nächsten Video angewandt, wenn die Sprache verfügbar ist.
NSString *SFSubtitleLanguage(void);
void SFSetSubtitleLanguage(NSString *lang);
