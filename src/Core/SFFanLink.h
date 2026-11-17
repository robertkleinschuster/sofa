// SFFanLink - Sofa and the fan daemon sofa-fand (helpers/sofa-fand): Sofa's context goes to the
// daemon, its thermal state comes back. Interface v1 (2026-11-17), datagrams only - the daemon does
// no disk I/O in its control loop (it must survive a hanging disk), Sofa never waits for it:
//  - hint, Sofa -> daemon: one JSON line to <dir>/hint.sock (AF_UNIX, SOCK_DGRAM), non-blocking,
//    dropped when nobody listens; sent from Sofa's own socket bound to a path of its own:
//    {"v":1,"ctx":"playback"|"idle"|"ruhe","vol":0..1|null,"ttl":90,"pid":N}
//  - state, daemon -> Sofa: the answer to every hint, and pushed at once on a level change, to the
//    hint's sender address: {"v":1,"level":0..3,"cpu_c":..,"gpu_c":..,"hdd_c":..,"amb_c":..,"fans":[..]}
//    level 0 normal, 1 warm, 2 hot, 3 critical (hysteresis in the daemon). No answer for 120 s =
//    no daemon (level 0) - counted by Sofa's clock when it received the state, never the daemon's.
// <dir> = /var/run/sofa-fand; dev instances only with SOFA_FAND_DIR (tests, a mock) - they never
// tell the real daemon anything. All socket work runs on one serial background queue.
#import <Foundation/Foundation.h>

extern NSString *const SFFanContextPlayback, *const SFFanContextIdle, *const SFFanContextRest;

// Start listening (idempotent); `state` is called on the main thread with every valid state the
// daemon sends (an NSNumber "level" 0..3 plus its other fields).
void SFFanStart(void (^state)(NSDictionary *s));
// volume 0..1, < 0 = unknown (null); ttl: seconds until the daemon falls back to its own control.
// Asynchronous; skipped while an earlier one still waits (a hanging disk stalls a path lookup).
void SFFanSendHint(NSString *context, float volume, int ttl);
// pure (tests): one datagram from the daemon -> the state, or nil when it is not a v1 state
NSDictionary *SFFanParseState(NSData *json);
