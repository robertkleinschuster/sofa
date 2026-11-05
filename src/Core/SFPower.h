// Power menu (MENU on home): Sofa is the smart-TV overlay of this iMac. Display off,
// sleep, sleep timer. macOS timeouts (pmset displaysleep 5, sleep 0) remain the
// idle fallback; this is the active control. Wake: any remote button
// (SofaRemote: the first press only wakes and brings Sofa to the front).
#import "SFCore.h"

// Before display off/sleep: pause the player + save progress.
extern NSString *const SFPowerWillTurnOffNotification;

@class SFNavigator;

@interface SFPower : NSObject
+ (void)displayOff;
+ (void)systemSleep;
+ (void)setSleepTimerMinutes:(NSInteger)minutes;   // 0 = off
+ (void)showPowerMenuOn:(SFNavigator *)nav;       // MENU on the home screen
+ (void)setNavigator:(SFNavigator *)nav;          // for notices (sleep timer)
@end
