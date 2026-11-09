#import "SFPrebufferReader.h"
#import "SFCore.h"
#import "SFHTTPBudget.h"
#import <mpv/client.h>
#include <math.h>

static const NSUInteger kMaxBytes = 16 * 1024 * 1024;   // response budget and stream bytes per read
static const NSTimeInterval kWallTime = 30;             // the whole read, whatever the source does
static const double kEnoughSeconds = 8;                 // buffered ahead of the position: done

@implementation SFPrebufferRead {
    BOOL _cancelled;
}

- (instancetype)init {
    if ((self = [super init])) _budgetToken = [SFHTTPBudget open:kMaxBytes];
    return self;
}

- (BOOL)cancelled { @synchronized(self) { return _cancelled; } }

- (void)setCancelled:(BOOL)value {
    @synchronized(self) {
        _cancelled = value;
        if (value) [SFHTTPBudget close:_budgetToken];
    }
}

- (void)dealloc { [SFHTTPBudget close:_budgetToken]; }

@end

// mpv options: name, value, required. A required one that fails ends the read (fail closed: no
// read without its limits or with a real output); this libmpv has no Lua/ytdl, so the optional
// script/input knobs may be missing.
static const struct { const char *name, *value; BOOL required; } kOptions[] = {
    {"vo", "null", YES}, {"ao", "null", YES}, {"pause", "yes", YES}, {"idle", "yes", NO},
    {"ytdl", "no", NO}, {"load-scripts", "no", NO}, {"config", "no", NO},
    {"input-default-bindings", "no", NO}, {"input-vo-keyboard", "no", NO}, {"terminal", "no", NO},
    {"msg-level", "all=no", NO}, {"cache", "yes", YES}, {"cache-pause", "no", NO},
    // cache-secs overrides readahead when cache=yes (otherwise defaults to 10000 hours)
    {"cache-secs", "12", YES}, {"demuxer-readahead-secs", "12", YES}, {"demuxer-max-bytes", "16MiB", YES},
    {"demuxer-max-back-bytes", "0", YES},
    // SABR token setup plus its first segment can exceed five seconds: playback's transport
    // timeout; the read keeps its own deadline and byte/cancellation limits
    {"network-timeout", "20", NO},
    {"sub-auto", "no", NO}, {"sid", "no", NO}, {"hr-seek", "yes", NO},
    {"demuxer-mkv-probe-start-time", "no", NO}, {"demuxer-mkv-probe-image", "no", NO},
};

@implementation SFPrebufferReader

+ (NSDictionary *)readURL:(NSURL *)url audio:(NSURL *)audio position:(double)position request:(SFPrebufferRead *)request {
    @autoreleasepool {
        if (request.cancelled || !url) return @{@"reason": @"cancelled"};
        mpv_handle *m = mpv_create();
        if (!m) return @{@"reason": @"create failed"};
        for (size_t i = 0; i < sizeof(kOptions) / sizeof(kOptions[0]); i++) {
            int rc = mpv_set_option_string(m, kOptions[i].name, kOptions[i].value);
            if (rc < 0 && (kOptions[i].required || rc != MPV_ERROR_OPTION_NOT_FOUND)) {
                mpv_terminate_destroy(m);
                return @{@"reason": @"option failed", @"option": @(kOptions[i].name)};
            }
        }
        NSString *budgetHeader = [@"X-Sofa-Read-Budget: " stringByAppendingString:request.budgetToken];
        if (mpv_set_option_string(m, "http-header-fields", budgetHeader.UTF8String) < 0) {
            mpv_terminate_destroy(m);
            return @{@"reason": @"budget header failed"};
        }
        position = isfinite(position) ? MAX(0, position) : 0;
        mpv_set_option_string(m, "start", [NSString stringWithFormat:@"%.3f", position].UTF8String);
        if (audio) mpv_set_option_string(m, "demuxer-lavf-probesize", "4096");
        if (mpv_initialize(m) < 0) { mpv_terminate_destroy(m); return @{@"reason": @"init failed"}; }
        if (audio) {
            const char *args[] = {"change-list", "audio-files", "append", audio.absoluteString.UTF8String, NULL};
            mpv_command(m, args);
        }
        const char *load[] = {"loadfile", url.absoluteString.UTF8String, "replace", NULL};
        if (mpv_command(m, load) < 0) { mpv_terminate_destroy(m); return @{@"reason": @"load failed"}; }

        NSTimeInterval began = [NSDate timeIntervalSinceReferenceDate];
        double buffered = 0;
        int64_t read = 0;
        NSString *reason = @"timeout";
        while (!request.cancelled && [NSDate timeIntervalSinceReferenceDate] - began < kWallTime) {
            mpv_event *e = mpv_wait_event(m, 0.1);
            if (e->event_id == MPV_EVENT_END_FILE || e->event_id == MPV_EVENT_SHUTDOWN) { reason = @"ended"; break; }
            mpv_get_property(m, "demuxer-cache-duration", MPV_FORMAT_DOUBLE, &buffered);
            mpv_get_property(m, "stream-bytes-read", MPV_FORMAT_INT64, &read);
            if (buffered >= kEnoughSeconds) { reason = @"bounded"; break; }
            if (![SFHTTPBudget remaining:request.budgetToken] || read >= (int64_t)kMaxBytes) { reason = @"byte limit"; break; }
        }
        if (request.cancelled) reason = @"cancelled";
        double elapsed = [NSDate timeIntervalSinceReferenceDate] - began, actual = -1;
        mpv_get_property(m, "time-pos", MPV_FORMAT_DOUBLE, &actual);
        // interrupt blocking reads before destroying; this worker is the handle's only owner
        const char *stop[] = {"stop", NULL};
        mpv_command_async(m, 0, stop);
        mpv_terminate_destroy(m);
        return @{@"reason": reason, @"seconds": @(elapsed), @"buffered": @(buffered), @"read": @(read),
                 @"position": @(actual), @"budgetRemaining": @([SFHTTPBudget remaining:request.budgetToken])};
    }
}

@end
