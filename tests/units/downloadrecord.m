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
  // a finished download with a pending repair, checked online, kept
  NSDictionary *full = @{@"id": @"example:1", @"source": @"example", @"channel": @"Show", @"item": @"{\"id\":\"example:1\"}",
                         @"state": @2, @"progress": @1.0, @"path": @"/x/1.mp4", @"thumb": @"/x/1.jpg", @"bytes": @123456789012LL,
                         @"added": @100.5, @"published": @90.0, @"sub": @"exampleshow:a", @"error": @"timeout", @"tries": @2,
                         @"retryAt": @2000.0, @"keep": @1, @"online": @0, @"onlineAt": @1500.0};
  SFDownloadRecord *r = [SFDownloadRecord recordWithRow:full];
  expect(r.state == SFDLDone && r.retryAt == 2000 && r.tries == 2, "state, repair pending, attempts");
  expect(r.bytes == 123456789012ULL && r.keep && r.online == 0, "bytes (> 4 GB), kept, gone at its source");
  NSDictionary *w = written(r.writeStatement);
  NSMutableDictionary *expected = [full mutableCopy]; [expected removeObjectForKey:@"item"];   // the item lives in items
  BOOL same = w.count == expected.count;
  for (NSString *k in expected) if (![[w[k] description] isEqualToString:[expected[k] description]]) { same = NO; printf("  %s: %s != %s\n", k.UTF8String, [[w[k] description] UTF8String], [[expected[k] description] UTF8String]); }
  expect(same, "written back unchanged (every column, no item column)");
  SFDownloadRecord *c = [r copy];
  expect([written(c.writeStatement) isEqualToDictionary:w] && [c.itemJSON isEqualToString:r.itemJSON], "a copy writes the same, keeps the item");

  // a fresh manual download: no file, no subscription, never checked
  SFDownloadRecord *m = [SFDownloadRecord recordWithRow:@{@"id": @"example:2", @"state": @0}];
  expect(m.online == -1 && !m.sub && !m.path && m.retryAt == 0 && m.published == 0, "absent values: unknown / none");
  NSDictionary *mw = written(m.writeStatement);
  NSNull *null = [NSNull null];
  expect(mw[@"online"] == null && mw[@"onlineAt"] == null && mw[@"retryAt"] == null && mw[@"published"] == null
         && mw[@"sub"] == null && mw[@"path"] == null && mw[@"error"] == null, "...written as NULL, not 0");
  expect([mw[@"source"] isEqual:@""] && [mw[@"channel"] isEqual:@""], "source/channel: empty text, never NULL");
  expect([SFDownloadRecord new].online == -1, "a new record: online unknown");

  // subscriptions
  SFSubscription *s = [SFSubscription subscriptionWithRow:@{@"id": @"exampleshow:a", @"since": @7.0, @"added": @5.0}];
  expect(s.keepDays == 90, "subscription: window defaults to 90 days");
  NSDictionary *sw = written(s.writeStatement);
  expect([sw[@"id"] isEqual:@"exampleshow:a"] && [sw[@"keepDays"] isEqual:@90] && [sw[@"since"] isEqual:@7.0] && [sw[@"added"] isEqual:@5.0], "subscription written back");
  return bad ? 1 : 0;
}}
