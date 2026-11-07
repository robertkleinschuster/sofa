// sources: src/Library/SFDownloadBudget.m
// SFDownloadBudget: starts older than 24 h stop counting; with `max` starts in the window the next
// may go once the oldest counting one leaves it; no limit (0) and room in the budget = now.
#import "../../src/Library/SFDownloadBudget.h"
#import "SFCore.h"
BOOL SFDevMode = NO;   // main.m's, for SFCore.m
static int bad = 0;
static void expect(BOOL c, const char *what) { printf("%s %s\n", c ? "ok  " : "FAIL", what); if (!c) bad++; }
int main(void) { @autoreleasepool {
    NSTimeInterval now = 1000000, h = 3600;
    NSArray *starts = @[@(now - 2 * h), @(now - 30 * h), @(now - 23 * h), @(now - 10 * h)];
    NSArray *recent = SFDownloadBudgetRecent(starts, now);
    expect([recent isEqualToArray:@[@(now - 23 * h), @(now - 10 * h), @(now - 2 * h)]], "older than 24 h dropped, oldest first");
    expect(SFDownloadBudgetFreeAt(recent, 0) == 0, "no limit: now");
    expect(SFDownloadBudgetFreeAt(recent, 4) == 0, "room in the budget: now");
    expect(SFDownloadBudgetFreeAt(recent, 3) == now + 1 * h, "budget used: when the oldest leaves the window");
    expect(SFDownloadBudgetFreeAt(recent, 2) == now + 14 * h, "smaller budget: when enough have left it");
    expect(SFDownloadBudgetFreeAt(@[], 18) == 0, "nothing started: now");
    expect(SFDownloadBudgetRecent(@[@(now - 24 * h)], now).count == 0, "exactly 24 h ago no longer counts");
    return bad ? 1 : 0;
} }
