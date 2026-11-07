// A source's daily download budget (SFApp subscriptionDownloadsPerDay), as pure functions: which
// starts still count, and when the next one may go. Kept by SFDownloads (Worker).
#import <Foundation/Foundation.h>

extern const NSTimeInterval SFDownloadBudgetWindow;   // 24 h

// `starts` (epochs, any order) within the window before `now`, oldest first.
NSArray *SFDownloadBudgetRecent(NSArray *starts, NSTimeInterval now);
// When the budget of `max` starts per window allows the next one, given the recent starts:
// 0 = now (also for max 0 = no limit), else the epoch the oldest counting start leaves the window.
NSTimeInterval SFDownloadBudgetFreeAt(NSArray *recent, NSUInteger max);
