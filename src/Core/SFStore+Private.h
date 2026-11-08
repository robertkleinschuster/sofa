// SFStore internals shared with its categories (SFStore+Schema.m). Call on the store's queue (or
// during init) only.
#import "SFStore.h"

@interface SFStore (Private)
- (void)exec:(NSString *)sql;
- (void)runNow:(NSString *)sql args:(NSArray *)args;
- (NSArray *)rowsNow:(NSString *)sql args:(NSArray *)args;
- (void)trimCacheNow;
- (NSUInteger)errorCount;   // failed statements so far (a schema step that adds one is rolled back)
- (void)failStep:(NSString *)why;   // a schema step's own check failed: counts as an error (rolled back)
@end

@interface SFStore (Schema)
- (void)migrate;   // init: run every schema step not applied yet
@end
