// "Fernseher"-Steuerung: Sofa ist die 10-Fuß-Shell des iMac (= TV). Bildschirm aus,
// Ruhezustand, Sleep-Timer. macOS-Timeouts (pmset displaysleep 5, sleep 0) bleiben der
// Leerlauf-Rückfall; das hier ist die aktive Steuerung. Wecken: jede Remote-Taste
// (SofaRemote: erster Druck weckt nur und holt Sofa nach vorne).
#import "SFCore.h"

// Vor Bildschirm-aus/Ruhezustand: Player pausieren + Fortschritt sichern.
extern NSString *const SFPowerWillTurnOffNotification;

@class SFNavigator;

@interface SFPower : NSObject
+ (void)displayOff;
+ (void)systemSleep;
+ (void)setSleepTimerMinutes:(NSInteger)minutes;   // 0 = aus
+ (NSDate *)sleepTimerFireDate;
+ (void)showPowerMenuOn:(SFNavigator *)nav;       // MENU auf dem Home-Screen
+ (void)setNavigator:(SFNavigator *)nav;          // für Hinweise (Sleep-Timer)
@end
