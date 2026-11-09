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
    r.sub = str(row[@"sub"]);
    r.error = str(row[@"error"]);
    r.tries = [row[@"tries"] integerValue];
    r.retryAt = [row[@"retryAt"] doubleValue];
    r.keep = [row[@"keep"] boolValue];
    r.expires = [row[@"expires"] doubleValue];
    r.online = row[@"online"] ? [row[@"online"] integerValue] : -1;
    r.onlineAt = [row[@"onlineAt"] doubleValue];
    return r;
}

static NSString *const kWrite = @"INSERT OR REPLACE INTO downloads (id,source,channel,thumb,state,progress,added,"
                                 "published,sub,error,tries,retryAt,keep,online,onlineAt,expires) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)";

- (NSArray *)writeStatement {
    return @[kWrite,
             @[_identifier, _source ?: @"", _channel ?: @"", orNull(_thumb), @(_state), @(_progress),
               @(_added), timeOrNull(_published), orNull(_sub), orNull(_error), @(_tries), timeOrNull(_retryAt),
               @(_keep), _online >= 0 ? @(_online) : [NSNull null], timeOrNull(_onlineAt), timeOrNull(_expires)]];
}

// Called before interrupted jobs are resumed or integrity checks can requeue anything.
// Keep explicit user intent; otherwise leave existing bytes as ordinary evictable cache.
- (BOOL)retireAutomaticFill {
    if (!_sub && _expires <= 0) return NO;
    _sub = nil; _expires = 0; _retryAt = 0;
    if (!_keep) {
        _state = SFDLDismissed; _progress = 0; _error = nil; _tries = 0;
    }
    return YES;
}

- (id)copyWithZone:(NSZone *)zone {
    SFDownloadRecord *c = [[self class] new];
    c.identifier = _identifier; c.source = _source; c.channel = _channel; c.itemJSON = _itemJSON;
    c.state = _state; c.progress = _progress; c.thumb = _thumb;
    c.added = _added; c.published = _published; c.sub = _sub; c.error = _error; c.tries = _tries;
    c.retryAt = _retryAt; c.keep = _keep; c.online = _online; c.onlineAt = _onlineAt; c.expires = _expires;
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

// an upsert: REPLACE would delete the row its episodes refer to
static NSString *const kWriteSubscription = @"INSERT INTO subscriptions (id,keepDays,since,added) VALUES (?,?,?,?) "
    "ON CONFLICT(id) DO UPDATE SET keepDays = excluded.keepDays, since = excluded.since, added = excluded.added";

- (NSArray *)writeStatement {
    return @[kWriteSubscription,
             @[_identifier, @(_keepDays ?: 90), @(_since), @(_added)]];
}

@end
