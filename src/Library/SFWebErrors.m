#import "SFWebErrors.h"

NSString *const SFWebErrBadRequest = @"bad_request";
NSString *const SFWebErrUnknownItem = @"unknown_item";
NSString *const SFWebErrNotVideo = @"not_video";
NSString *const SFWebErrNotDownloadable = @"not_downloadable";
NSString *const SFWebErrBadAction = @"bad_action";
NSString *const SFWebErrBadState = @"bad_state";
NSString *const SFWebErrNotPaired = @"not_paired";
NSString *const SFWebErrWrongCode = @"wrong_code";
NSString *const SFWebErrDRM = @"drm";
NSString *const SFWebErrBadSignature = @"bad_signature";
NSString *const SFWebErrForbidden = @"forbidden";
NSString *const SFWebErrNotFound = @"not_found";
NSString *const SFWebErrNoSearch = @"no_search";
NSString *const SFWebErrTVIdle = @"tv_idle";
NSString *const SFWebErrNoPicture = @"no_picture";
NSString *const SFWebErrUnsupportedVersion = @"unsupported_version";
NSString *const SFWebErrMethodNotAllowed = @"method_not_allowed";
NSString *const SFWebErrTVBusy = @"tv_busy";
NSString *const SFWebErrNoPairingOpen = @"no_pairing_open";
NSString *const SFWebErrPageGone = @"page_gone";
NSString *const SFWebErrStreamGone = @"stream_gone";
NSString *const SFWebErrNotPlayable = @"not_playable";
NSString *const SFWebErrEncoderBusy = @"encoder_busy";
NSString *const SFWebErrRateLimited = @"rate_limited";
NSString *const SFWebErrInternal = @"internal";
NSString *const SFWebErrUpstream = @"upstream";
NSString *const SFWebErrNotReady = @"not_ready";
NSString *const SFWebErrTimeout = @"timeout";

NSArray *SFWebErrorCodes(void) {
    return [@[SFWebErrBadRequest, SFWebErrUnknownItem, SFWebErrNotVideo, SFWebErrNotDownloadable, SFWebErrBadAction, SFWebErrBadState,
              SFWebErrNotPaired, SFWebErrWrongCode, SFWebErrDRM, SFWebErrBadSignature, SFWebErrForbidden, SFWebErrNotFound,
              SFWebErrNoSearch, SFWebErrTVIdle, SFWebErrNoPicture, SFWebErrUnsupportedVersion, SFWebErrMethodNotAllowed,
              SFWebErrTVBusy, SFWebErrNoPairingOpen, SFWebErrPageGone, SFWebErrStreamGone, SFWebErrNotPlayable,
              SFWebErrEncoderBusy, SFWebErrRateLimited, SFWebErrInternal, SFWebErrUpstream, SFWebErrNotReady, SFWebErrTimeout]
            sortedArrayUsingSelector:@selector(compare:)];
}

NSDictionary *SFWebError(NSString *code, NSString *message) {
    return @{@"error": message ?: @"", @"code": code ?: SFWebErrInternal};
}
