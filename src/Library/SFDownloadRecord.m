#import "SFDownloadRecord.h"

static NSString *str(id v) { return [v isKindOfClass:[NSString class]] && [v length] ? v : nil; }
static id orNull(id v) { return v ?: [NSNull null]; }
static id timeOrNull(NSTimeInterval t) { return t > 0 ? @(t) : [NSNull null]; }

@implementation SFDownloadRecord

- (instancetype)init {
    if ((self = [super init])) { _online = -1; _channel = @""; }
    return self;
}

+ (instancetype)recordWithRow:(NSDictionary *)row {
    SFDownloadRecord *r = [self new];
    r.identifier = str(row[@"id"]);
    r.source = str(row[@"source"]) ?: @"";
    r.channel = str(row[@"channel"]) ?: @"";
    r.itemJSON = str(row[@"item"]);
    r.state = [row[@"state"] integerValue];
    r.progress = [row[@"progress"] doubleValue];
    r.thumb = str(row[@"thumb"]);
    r.added = [row[@"added"] doubleValue];
    r.published = [row[@"published"] doubleValue];
    r.error = str(row[@"error"]);
    r.keep = [row[@"keep"] boolValue];
    r.online = row[@"online"] ? [row[@"online"] integerValue] : -1;
    r.onlineAt = [row[@"onlineAt"] doubleValue];
    return r;
}

static NSString *const kWrite = @"INSERT OR REPLACE INTO downloads (id,source,channel,thumb,state,progress,added,"
                                 "published,error,keep,online,onlineAt) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)";

- (NSArray *)writeStatement {
    return @[kWrite,
             @[_identifier, _source ?: @"", _channel ?: @"", orNull(_thumb), @(_state), @(_progress),
               @(_added), timeOrNull(_published), orNull(_error), @(_keep), _online >= 0 ? @(_online) : [NSNull null], timeOrNull(_onlineAt)]];
}

- (id)copyWithZone:(NSZone *)zone {
    SFDownloadRecord *c = [[self class] new];
    c.identifier = _identifier; c.source = _source; c.channel = _channel; c.itemJSON = _itemJSON;
    c.state = _state; c.progress = _progress; c.thumb = _thumb;
    c.added = _added; c.published = _published; c.error = _error;
    c.keep = _keep; c.online = _online; c.onlineAt = _onlineAt;
    return c;
}

@end
