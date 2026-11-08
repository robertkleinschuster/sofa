// SFExtentSet - the byte ranges of a track that are on disk (SFMediaStore, docs/media-store.md):
// half-open [start, end) ranges, kept sorted and coalesced (overlapping and touching ones merge).
// A value object without I/O - the store keeps one per track and persists its ranges.
#import <Foundation/Foundation.h>

@interface SFExtentSet : NSObject <NSCopying>
+ (instancetype)setWithRanges:(NSArray *)ranges;   // @[@[@start, @end], ...] in any order (persisted form)
- (void)addStart:(long long)start end:(long long)end;
- (void)removeStart:(long long)start end:(long long)end;
- (BOOL)coversStart:(long long)start end:(long long)end;
- (long long)contiguousFrom:(long long)start;       // bytes present from `start` on without a gap (0: none)
- (NSArray *)missingFrom:(long long)start to:(long long)end;   // the gaps within [start, end), as @[@s, @e]
@property (nonatomic, readonly) NSArray *ranges;    // sorted, coalesced, as @[@start, @end]
@property (nonatomic, readonly) long long bytes;    // their total length
@end
