// Start-Einstellungen, die auch der Helper (SofaRemote) liest: macOS-Preferences statt SQLite.
// Domain de.sofa.app (Dev-Instanzen: de.sofa.dev, nie die echte App beeinflussen).
#import <Foundation/Foundation.h>

BOOL SFAutostartEnabled(void);            // beim Anmelden starten (Standard: an)
void SFSetAutostartEnabled(BOOL on);
BOOL SFRemoteLaunchEnabled(void);         // geschlossenes Sofa mit MENU der Apple Remote starten (Standard: an)
void SFSetRemoteLaunchEnabled(BOOL on);
BOOL SFStartupQuestionsAsked(void);       // Ersteinrichtung hat beides abgefragt
void SFSetStartupQuestionsAsked(void);
