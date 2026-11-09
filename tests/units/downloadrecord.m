// sources: src/Library/SFDownloadRecord.m
// SFDownloadRecord / SFSubscription: a database row read into the record and written back - absent
// values stay absent (NULL), "unknown" stays unknown, nothing is invented on the way.
#import "../../src/Library/SFDownloadRecord.h"
#import "SFCore.h"
BOOL SFDevMode = NO;
static int bad = 0;
static void expect(BOOL c, const char *what) { printf("%s %s\n", c ? "ok  " : "FAIL", what); if (!c) bad++; }
static NSDictionary *written(NSArray *w) {   // the statement's columns -> values
    NSString *cols = [w[0] substringFromIndex:[w[0] rangeOfString:@"("].location + 1];
    cols = [cols substringToIndex:[cols rangeOfString:@")"].location];
    return [NSDictionary dictionaryWithObjects:w[1] forKeys:[cols componentsSeparatedByString:@","]];
}
int main(void){ @autoreleasepool {
  // a finished subscription episode after a failed attempt, checked online, kept, expiring
  NSDictionary *full = @{@"id": @"example:1", @"source": @"example", @"channel": @"Show", @"item": @"{\"id\":\"example:1\"}",
                         @"state": @2, @"progress": @1.0, @"thumb": @"/x/1.jpg",
                         @"added": @100.5, @"published": @90.0, @"sub": @"exampleshow:a", @"error": @"timeout", @"tries": @2,
                         @"retryAt": @2000.0, @"keep": @1, @"online": @0, @"onlineAt": @1500.0, @"expires": @3000.0};
  SFDownloadRecord *r = [SFDownloadRecord recordWithRow:full];
  expect(r.state == SFDLDone && r.retryAt == 2000 && r.tries == 2, "state, next attempt, attempts");
  expect(r.keep && r.online == 0, "kept, gone at its source");
  NSDictionary *w = written(r.writeStatement);
  NSMutableDictionary *expected = [full mutableCopy]; [expected removeObjectForKey:@"item"];   // the item lives in items
  BOOL same = w.count == expected.count;
  for (NSString *k in expected) if (![[w[k] description] isEqualToString:[expected[k] description]]) { same = NO; printf("  %s: %s != %s\n", k.UTF8String, [[w[k] description] UTF8String], [[expected[k] description] UTF8String]); }
  expect(same, "written back unchanged (every column, no item column)");
  SFDownloadRecord *c = [r copy];
  expect([written(c.writeStatement) isEqualToDictionary:w] && [c.itemJSON isEqualToString:r.itemJSON], "a copy writes the same, keeps the item");

  // a fresh manual download: no subscription, never checked
  SFDownloadRecord *m = [SFDownloadRecord recordWithRow:@{@"id": @"example:2", @"state": @0}];
  expect(m.online == -1 && !m.sub && m.retryAt == 0 && m.published == 0, "absent values: unknown / none");
  NSDictionary *mw = written(m.writeStatement);
  NSNull *null = [NSNull null];
  expect(mw[@"online"] == null && mw[@"onlineAt"] == null && mw[@"retryAt"] == null && mw[@"published"] == null
         && mw[@"sub"] == null && mw[@"error"] == null && mw[@"expires"] == null, "...written as NULL, not 0");
  expect([mw[@"source"] isEqual:@""] && [mw[@"channel"] isEqual:@""], "source/channel: empty text, never NULL");
  expect([SFDownloadRecord new].online == -1, "a new record: online unknown");

  // Upgrade: queued/running/retrying automatic jobs cannot restart full fills; completed
  // automatic copies become plain cache too. Every manual state remains untouched.
  for (NSInteger state = SFDLQueued; state <= SFDLRetrying; state++) {
      SFDownloadRecord *automatic = [SFDownloadRecord recordWithRow:@{@"id": @"example:auto", @"state": @(state), @"sub": @"exampleshow:a", @"retryAt": @999}];
      expect([automatic retireAutomaticFill] && automatic.state == SFDLDismissed && !automatic.sub && !automatic.retryAt, "automatic work retired before recovery");
      expect(![automatic retireAutomaticFill], "migration idempotent");
      SFDownloadRecord *manual = [SFDownloadRecord recordWithRow:@{@"id": @"example:manual", @"state": @(state)}];
      expect(![manual retireAutomaticFill] && manual.state == state, "manual intent unchanged");
  }
  SFDownloadRecord *kept = [SFDownloadRecord recordWithRow:full];
  expect([kept retireAutomaticFill] && kept.state == SFDLDone && kept.keep && !kept.sub && !kept.expires, "explicitly kept copy survives without expiry");
  SFDownloadRecord *detached = [SFDownloadRecord recordWithRow:@{@"id": @"example:detached", @"state": @2, @"expires": @3000}];
  expect([detached retireAutomaticFill] && detached.state == SFDLDismissed, "expired-policy copy without subscription becomes cache");

  // subscriptions
  SFSubscription *s = [SFSubscription subscriptionWithRow:@{@"id": @"exampleshow:a", @"since": @7.0, @"added": @5.0}];
  expect(s.keepDays == 90, "subscription: window defaults to 90 days");
  NSDictionary *sw = written(s.writeStatement);
  expect([sw[@"id"] isEqual:@"exampleshow:a"] && [sw[@"keepDays"] isEqual:@90] && [sw[@"since"] isEqual:@7.0] && [sw[@"added"] isEqual:@5.0], "subscription written back");
  return bad ? 1 : 0;
}}
