// SFMP4Index - where the media of a progressive MP4 file lies in time (docs/media-store.md 5c): the
// moov box's sample tables (stco/co64 chunk offsets, stsc samples per chunk, stsz sizes, stts
// durations, an edit list's start) give every chunk of every audio/video track its byte span and
// time span. Exact - what the player's timeline shows of a file on disk.
#import <Foundation/Foundation.h>

@interface SFMP4Index : NSObject
// Parses the file through `read` (bytes [off, off+len) or nil when not there); nil when the moov
// box is not (yet) readable or not an MP4.
+ (instancetype)indexWithLength:(long long)total read:(NSData *(^)(long long off, NSUInteger len))read;
// per audio/video track its chunks, sorted by time: @[@[@(byte start), @(byte end), @(t0 s), @(t1 s)]]
@property (nonatomic, readonly) NSArray *tracks;
// Time ranges @[@[start s, end s]] where every track's chunks are whole within `covered`
// (covered(start, end): the bytes are all there)
- (NSArray *)storedRanges:(BOOL (^)(long long start, long long end))covered;
@end
