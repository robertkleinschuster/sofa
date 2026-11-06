// SFDownloadRecord - one row of the downloads table as a typed record: what Sofa knows about one
// download (its item's metadata is in the items table). SFSubscription - one row of subscriptions.
// Both read their row (recordWithRow:) and give the statement that stores them (writeStatement,
// for SFStore run:/runAll:). Absent values: nil for strings, 0 for times, -1 for "unknown".
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SFDLState) {
    SFDLNone = -1,
    SFDLQueued = 0,
    SFDLRunning = 1,
    SFDLDone = 2,
    SFDLFailed = 3,        // gave up (manual download, or a subscription episode after kSubMaxTries)
    SFDLDismissed = 4,     // deleted by the user -> the subscription does not download it again
    SFDLRetrying = 5,      // a subscription episode failed; Sofa tries again by itself at retryAt
};

@interface SFDownloadRecord : NSObject <NSCopying>
@property (nonatomic, copy) NSString *identifier;   // the item's source ID
@property (nonatomic, copy) NSString *source;       // app name ("youtube", ...)
@property (nonatomic, copy) NSString *channel;      // its show (a subscription's name wins over the item's); may be empty
@property (nonatomic, copy) NSString *itemJSON;     // the item as last read/written (items table)
@property (nonatomic) SFDLState state;
@property (nonatomic) double progress;              // 0..1 while loading
@property (nonatomic, copy) NSString *path;         // the file (Done; kept during a repair)
@property (nonatomic, copy) NSString *thumb;        // local thumbnail
@property (nonatomic) unsigned long long bytes;
@property (nonatomic) NSTimeInterval added;         // when it was requested (queue order)
@property (nonatomic) NSTimeInterval published;     // publication time (exact when the source gave one); 0 = unknown
@property (nonatomic, copy) NSString *sub;          // the subscription that fetched it; nil = manual
@property (nonatomic, copy) NSString *error;        // last failure
@property (nonatomic) NSInteger tries;              // failed attempts so far
// the earliest next attempt - of the download (Retrying, also a manual Failed one a subscription
// finds later) or of the repair of a finished file (Done + retryAt = a repair is pending, the old
// file stays playable); 0 = nothing pending
@property (nonatomic) NSTimeInterval retryAt;
@property (nonatomic) BOOL keep;                    // "Behalten": never in a bulk deletion
@property (nonatomic) NSInteger online;             // at its source: 1 online, 0 gone, -1 not checked
@property (nonatomic) NSTimeInterval onlineAt;      // when that was checked

+ (instancetype)recordWithRow:(NSDictionary *)row;  // a row of "SELECT d.*, i.json AS item ..."
- (NSArray *)writeStatement;                        // @[sql, args]
@end

@interface SFSubscription : NSObject
@property (nonatomic, copy) NSString *identifier;   // = its follow's id
@property (nonatomic) NSInteger keepDays;           // download window
@property (nonatomic) NSTimeInterval since;         // only episodes after this (set on the first check); 0 = not checked yet
@property (nonatomic) NSTimeInterval added;
+ (instancetype)subscriptionWithRow:(NSDictionary *)row;
- (NSArray *)writeStatement;
@end
