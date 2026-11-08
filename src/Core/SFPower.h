// Power: Sofa is the smart-TV overlay of this iMac. Switching off ("Ausschalten", today the
// display), sleep, sleep timer. macOS timeouts (pmset displaysleep 5, sleep 0) remain the
// idle fallback; this is the active control. Wake: any remote button
// (SofaRemote: the first press only wakes and brings Sofa to the front).
#import "SFCore.h"

// Before display off/sleep: pause the player + save progress.
extern NSString *const SFPowerWillTurnOffNotification;

@class SFNavigator;

@interface SFPower : NSObject
// "Ausschalten" (the quick menu's first entry): what switching Sofa off means is this one place's
// decision - today the display goes off; smarter sleep/wake behaviour comes here later (user 2026-11-08)
+ (void)switchOff;
+ (void)displayOff;
+ (void)systemSleep;
+ (void)setSleepTimerMinutes:(NSInteger)minutes;   // 0 = off
+ (void)showPowerMenuOn:(SFNavigator *)nav;       // "Energie" in the quick menu: sleep timer, Ruhezustand
+ (void)setNavigator:(SFNavigator *)nav;          // for notices (sleep timer)
@end
