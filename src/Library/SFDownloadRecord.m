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
    r.path = str(row[@"path"]);
    r.thumb = str(row[@"thumb"]);
    r.bytes = [row[@"bytes"] unsignedLongLongValue];
    r.added = [row[@"added"] doubleValue];
    r.published = [row[@"published"] doubleValue];
    r.sub = str(row[@"sub"]);
    r.error = str(row[@"error"]);
    r.tries = [row[@"tries"] integerValue];
    r.retryAt = [row[@"retryAt"] doubleValue];
    r.keep = [row[@"keep"] boolValue];
    r.inStore = [row[@"store"] boolValue];
    r.online = row[@"online"] ? [row[@"online"] integerValue] : -1;
    r.onlineAt = [row[@"onlineAt"] doubleValue];
    return r;
}

static NSString *const kWrite = @"INSERT OR REPLACE INTO downloads (id,source,channel,path,thumb,state,progress,bytes,added,"
                                 "published,sub,error,tries,retryAt,keep,online,onlineAt,store) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)";

- (NSArray *)writeStatement {
    return @[kWrite,
             @[_identifier, _source ?: @"", _channel ?: @"", orNull(_path), orNull(_thumb), @(_state), @(_progress),
               @(_bytes), @(_added), timeOrNull(_published), orNull(_sub), orNull(_error), @(_tries), timeOrNull(_retryAt),
               @(_keep), _online >= 0 ? @(_online) : [NSNull null], timeOrNull(_onlineAt), @(_inStore)]];
}

- (id)copyWithZone:(NSZone *)zone {
    SFDownloadRecord *c = [[self class] new];
    c.identifier = _identifier; c.source = _source; c.channel = _channel; c.itemJSON = _itemJSON;
    c.state = _state; c.progress = _progress; c.path = _path; c.thumb = _thumb; c.bytes = _bytes;
    c.added = _added; c.published = _published; c.sub = _sub; c.error = _error; c.tries = _tries;
    c.retryAt = _retryAt; c.keep = _keep; c.online = _online; c.onlineAt = _onlineAt; c.inStore = _inStore;
    return c;
}

@end

@implementation SFSubscription

+ (instancetype)subscriptionWithRow:(NSDictionary *)row {
    SFSubscription *s = [self new];
    s.identifier = str(row[@"id"]);
    s.keepDays = [row[@"keepDays"] integerValue] ?: 90;
    s.since = [row[@"since"] doubleValue];
    s.added = [row[@"added"] doubleValue];
    return s;
}

- (NSArray *)writeStatement {
    return @[@"INSERT OR REPLACE INTO subscriptions (id,keepDays,since,added) VALUES (?,?,?,?)",
             @[_identifier, @(_keepDays ?: 90), @(_since), @(_added)]];
}

@end
