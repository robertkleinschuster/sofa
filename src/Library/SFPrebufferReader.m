#import "SFPrebufferReader.h"
#import "SFCore.h"
#import "SFHTTPBudget.h"
#import <mpv/client.h>
#include <math.h>

@implementation SFPrebufferRead { BOOL _cancelled; }
- (instancetype)init { if((self=[super init])) _budgetToken=[SFHTTPBudget open:16*1024*1024]; return self; }
- (BOOL)cancelled { @synchronized(self) { return _cancelled; } }
- (void)setCancelled:(BOOL)value { @synchronized(self) { _cancelled=value; if(value) [SFHTTPBudget close:_budgetToken]; } }
- (void)dealloc { [SFHTTPBudget close:_budgetToken]; }
@end
@implementation SFPrebufferReader
+ (NSDictionary *)readURL:(NSURL *)url audio:(NSURL *)audio position:(double)position request:(SFPrebufferRead *)request {
    @autoreleasepool {
        if (request.cancelled || !url) return @{@"reason": @"cancelled"};
        mpv_handle *m = mpv_create();
        if (!m) return @{@"reason": @"create failed"};
        const char *options[][2] = {
            {"vo", "null"}, {"ao", "null"}, {"pause", "yes"}, {"idle", "yes"},
            {"ytdl", "no"}, {"load-scripts", "no"}, {"config", "no"},
            {"input-default-bindings", "no"}, {"input-vo-keyboard", "no"}, {"terminal", "no"},
            {"msg-level", "all=no"}, {"cache", "yes"}, {"cache-pause", "no"},
            // cache-secs overrides readahead when cache=yes (otherwise defaults to 10000 hours).
            {"cache-secs", "12"}, {"demuxer-readahead-secs", "12"}, {"demuxer-max-bytes", "16MiB"},
            // SABR token setup plus its first segment can exceed five seconds.
            // Match playback's transport timeout; the whole reader still has
            // its independent 30-second deadline and byte/cancellation limits.
            {"demuxer-max-back-bytes", "0"}, {"network-timeout", "20"},
            {"sub-auto", "no"}, {"sid", "no"}, {"hr-seek", "yes"},
            {"demuxer-mkv-probe-start-time", "no"}, {"demuxer-mkv-probe-image", "no"},
        };
        // Fail closed when a required resource limit is unavailable.
        for (NSUInteger i=0; i<sizeof(options)/sizeof(options[0]); i++) {
            int rc = mpv_set_option_string(m, options[i][0], options[i][1]);
            NSString *opt = @(options[i][0]);
            // This libmpv has no Lua/ytdl support. Missing optional script/input knobs
            // need no substitute; cache limits and paused/null outputs are mandatory.
            BOOL required = [opt hasPrefix:@"demuxer-max-"] || [opt isEqual:@"demuxer-readahead-secs"] || [opt isEqual:@"cache-secs"]
                         || [opt isEqual:@"pause"] || [opt isEqual:@"cache"] || [opt isEqual:@"vo"] || [opt isEqual:@"ao"];
            if (rc < 0 && (required || rc != MPV_ERROR_OPTION_NOT_FOUND)) {
                mpv_terminate_destroy(m);
                return @{@"reason": @"option failed", @"option": opt};
            }
        }
        NSString *budgetHeader=[@"X-Sofa-Read-Budget: " stringByAppendingString:request.budgetToken];
        if (mpv_set_option_string(m,"http-header-fields",budgetHeader.UTF8String)<0) {
            mpv_terminate_destroy(m); return @{@"reason":@"budget header failed"};
        }
        position = isfinite(position) ? MAX(0, position) : 0;
        NSString *start = [NSString stringWithFormat:@"%.3f", position];
        mpv_set_option_string(m, "start", start.UTF8String);
        if (audio) mpv_set_option_string(m, "demuxer-lavf-probesize", "4096");
        if (mpv_initialize(m)<0) { mpv_terminate_destroy(m); return @{@"reason": @"init failed"}; }
        if (audio) {
            const char *args[] = {"change-list", "audio-files", "append", audio.absoluteString.UTF8String, NULL};
            mpv_command(m,args);
        }
        const char *load[] = {"loadfile", url.absoluteString.UTF8String, "replace", NULL};
        if (mpv_command(m, load)<0) { mpv_terminate_destroy(m); return @{@"reason": @"load failed"}; }
        NSTimeInterval began = [NSDate timeIntervalSinceReferenceDate];
        double buffered=0; int64_t read=0; NSString *reason=@"timeout";
        while (!request.cancelled && [NSDate timeIntervalSinceReferenceDate]-began<30) {
            mpv_event *e = mpv_wait_event(m, 0.1);
            if (e->event_id==MPV_EVENT_END_FILE || e->event_id==MPV_EVENT_SHUTDOWN) { reason=@"ended"; break; }
            mpv_get_property(m,"demuxer-cache-duration",MPV_FORMAT_DOUBLE,&buffered);
            mpv_get_property(m,"stream-bytes-read",MPV_FORMAT_INT64,&read);
            if (buffered>=8) { reason=@"bounded"; break; }
            if (![SFHTTPBudget remaining:request.budgetToken] || read>=16*1024*1024) { reason=@"byte limit"; break; }
        }
        if (request.cancelled) reason=@"cancelled";
        double elapsed=[NSDate timeIntervalSinceReferenceDate]-began;
        double actual = -1;
        mpv_get_property(m,"time-pos",MPV_FORMAT_DOUBLE,&actual);
        // Interrupt blocking reads before destroying; this worker is the only owner of the handle.
        const char *stop[]={"stop",NULL};mpv_command_async(m,0,stop);
        mpv_terminate_destroy(m);
        return @{@"reason":reason,@"seconds":@(elapsed),@"buffered":@(buffered),@"read":@(read),@"position":@(actual),
                 @"budgetRemaining":@([SFHTTPBudget remaining:request.budgetToken])};
    }
}
@end
