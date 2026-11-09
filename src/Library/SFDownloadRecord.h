// SFDownloadRecord - one row of the downloads table as a typed record: what Sofa knows about one
// download - the item's tracks in the media store (docs/media-store.md; its metadata is in the items
// table). Reads its row (recordWithRow:) and gives the statement that stores it (writeStatement,
// for SFStore run:/runAll:). Absent values: nil for strings, 0 for times, -1 for "unknown".
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SFDLState) {
    SFDLNone = -1,
    SFDLQueued = 0,
    SFDLRunning = 1,
    SFDLDone = 2,
    SFDLFailed = 3,        // gave up; "Herunterladen" tries again
};

@interface SFDownloadRecord : NSObject <NSCopying>
@property (nonatomic, copy) NSString *identifier;   // the item's source ID
@property (nonatomic, copy) NSString *source;       // app name ("youtube", ...)
@property (nonatomic, copy) NSString *channel;      // its show; may be empty
@property (nonatomic, copy) NSString *itemJSON;     // the item as last read/written (items table)
@property (nonatomic) SFDLState state;
@property (nonatomic) double progress;              // 0..1 while loading
@property (nonatomic, copy) NSString *thumb;        // local thumbnail
@property (nonatomic) NSTimeInterval added;         // when it was requested (queue order)
@property (nonatomic) NSTimeInterval published;     // publication time (exact when the source gave one); 0 = unknown
@property (nonatomic, copy) NSString *error;        // last failure
@property (nonatomic) BOOL keep;                    // "Behalten": never in a bulk deletion
@property (nonatomic) NSInteger online;             // at its source: 1 online, 0 gone, -1 not checked
@property (nonatomic) NSTimeInterval onlineAt;      // when that was checked

+ (instancetype)recordWithRow:(NSDictionary *)row;  // a row of "SELECT d.*, i.json AS item ..."
- (NSArray *)writeStatement;                        // @[sql, args]
@end
