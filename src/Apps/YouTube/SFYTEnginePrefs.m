#import "SFYTEnginePrefs.h"

// user.js of the engine profile. Every value is a reason, grouped by it.
NSDictionary *SFYTEnginePrefs(void) {
    return @{
        // Sofa's own extension: unsigned and sideloaded (Firefox ESR honours these)
        @"xpinstall.signatures.required": @NO, @"extensions.autoDisableScopes": @0, @"extensions.enabledScopes": @15,
        // The firefox-x11 port's defaults are tuned for remote X (files/firefox-x11-remote.js); what
        // a page can see of them goes back to stock Firefox: a user's browser, not a remote-X one.
        // WebGL needs the GPU process (gfxPlatform disables it without); Mesa's softpipe needs force.
        @"layers.gpu-process.enabled": @YES, @"webgl.disabled": @NO, @"webgl.force-enabled": @YES,
        @"layout.frame_rate": @-1, @"ui.prefersReducedMotion": @0, @"image.animation_mode": @"normal",
        @"general.smoothScroll": @YES, @"toolkit.cosmeticAnimations.enabled": @YES,
        @"media.autoplay.default": @1, @"media.autoplay.blocking_policy": @0,
        @"media.hardware-video-decoding.enabled": @YES, @"fission.autostart": @YES, @"dom.ipc.processCount": @8,
        // One YouTube tab needs one warm spare, rather than desktop Firefox's three.
        // Preserve fission and the active-process limits; this saves two idle processes.
        @"dom.ipc.processPrelaunch.fission.number": @1,
        // nobody looks at this browser: no first-run pages, prompts or crash-restore dialogs
        @"browser.shell.checkDefaultBrowser": @NO, @"browser.aboutwelcome.enabled": @NO,
        @"browser.startup.homepage_override.mstone": @"ignore", @"browser.sessionstore.resume_from_crash": @NO,
        @"browser.startup.page": @0,
        @"datareporting.policy.dataSubmissionEnabled": @NO, @"toolkit.telemetry.reportingpolicy.firstRun": @NO,
        @"app.update.enabled": @NO, @"toolkit.telemetry.enabled": @NO,
        // the TV's languages
        @"intl.accept_languages": @"de-AT, de, en-US, en",
        // IPv4 only (user decision 2026-11-07): YouTube had blocked this home's IPv6 /64 (its own
        // player failed there with a fresh profile) while IPv4 played; one address family for the
        // one identity
        @"network.dns.disableIPv6": @YES,
        // the engine never plays anything itself; a page that does stays silent
        @"media.volume_scale": @"0.0",
        // HTTP cache in RAM only (64 MB): on disk it held ~1 GB, 986 MB of it SABR answers (POSTs,
        // never served again; Sofa's media store keeps the bytes) - ~12.5 MB/min written during
        // playback, and its index rebuilt after every hard restart (2533 reads/min). The requests
        // stay the same (a fetch with cache: 'no-store' would add Pragma/Cache-Control). 2026-11-17
        @"browser.cache.disk.enable": @NO, @"browser.cache.disk.smart_size.enabled": @NO,
        @"browser.cache.memory.capacity": @65536,
        // Slim engine (user 2026-11-17: as lean as sensible). Only browser-side services nobody uses
        // here: nothing a page can see and no request to YouTube changes (user agent, headers,
        // HTTP/2/3, TLS, JS features, WebGL/canvas/codecs, cookies/storage stay; page-driven
        // prefetch/preconnect, favicon loads, push, GMP codecs and remote settings - certificate
        // revocation - stay on purpose).
        // - the new-tab page and its feeds (topsites, Pocket stories, weather, sponsored tiles from
        //   contile): fetched and written to activity-stream.*.json for a tab nobody opens; no
        //   preloaded about:newtab (a privileged content process of its own)
        @"browser.newtabpage.enabled": @NO, @"browser.newtab.preload": @NO,
        @"browser.newtabpage.activity-stream.feeds.topsites": @NO,
        @"browser.newtabpage.activity-stream.feeds.section.topstories": @NO,
        @"browser.newtabpage.activity-stream.feeds.weatherfeed": @NO,
        @"browser.newtabpage.activity-stream.showWeather": @NO,
        @"browser.newtabpage.activity-stream.showSponsored": @NO,
        @"browser.newtabpage.activity-stream.showSponsoredTopSites": @NO,
        @"browser.newtabpage.activity-stream.feeds.telemetry": @NO,
        @"browser.newtabpage.activity-stream.telemetry": @NO,
        @"browser.topsites.contile.enabled": @NO, @"extensions.pocket.enabled": @NO,
        // - history: places.sqlite(-wal) written on every navigation of the engine page, nobody reads
        //   it (a page never sees history; :visited is not exposed to it)
        @"places.history.enabled": @NO,
        // - page thumbnails for the new-tab page
        @"browser.pagethumbnails.capturing_disabled": @YES,
        // - Safe Browsing list updates (MBs to safebrowsing/ on a timer, requests to Google's SB
        //   API, not to YouTube); the engine only ever loads youtube.com
        @"browser.safebrowsing.malware.enabled": @NO, @"browser.safebrowsing.phishing.enabled": @NO,
        @"browser.safebrowsing.downloads.enabled": @NO, @"browser.safebrowsing.blockedURIs.enabled": @NO,
        // - telemetry, studies, experiments, crash report uploads (pings and their files on disk)
        @"toolkit.telemetry.unified": @NO, @"toolkit.telemetry.archive.enabled": @NO,
        @"toolkit.telemetry.newProfilePing.enabled": @NO, @"toolkit.telemetry.shutdownPingSender.enabled": @NO,
        @"toolkit.telemetry.firstShutdownPing.enabled": @NO, @"toolkit.telemetry.updatePing.enabled": @NO,
        @"toolkit.telemetry.bhrPing.enabled": @NO,
        @"datareporting.healthreport.uploadEnabled": @NO, @"datareporting.usage.uploadEnabled": @NO,
        @"app.normandy.enabled": @NO, @"app.shield.optoutstudies.enabled": @NO,
        @"messaging-system.rsexperimentloader.enabled": @NO, @"nimbus.rollouts.enabled": @NO,
        @"browser.ping-centre.telemetry": @NO, @"browser.discovery.enabled": @NO,
        @"browser.tabs.crashReporting.sendReport": @NO,
        // - update checks of the add-ons, search engines and system add-ons (the browser's own are
        //   off above; the bundle replaces the browser, Sofa's extension is sideloaded)
        @"app.update.auto": @NO, @"extensions.update.enabled": @NO, @"extensions.getAddons.cache.enabled": @NO,
        @"extensions.systemAddon.update.enabled": @NO, @"browser.search.update": @NO,
        @"browser.region.update.enabled": @NO,
        // - captive-portal and connectivity probes (detectportal.firefox.com on every network
        //   change; the log's "Could not determine network status" is the service failing anyway)
        @"network.captive-portal-service.enabled": @NO, @"network.connectivity-service.enabled": @NO,
        // - search suggestions, page translation and local ML features (model downloads)
        @"browser.search.suggest.enabled": @NO, @"browser.translations.enable": @NO,
        @"browser.translations.automaticallyPopup": @NO, @"browser.ml.enable": @NO,
        // - tours, promos and the Firefox account (sync)
        @"browser.uitour.enabled": @NO, @"identity.fxaccounts.enabled": @NO, @"browser.vpn_promo.enabled": @NO,
        // - session store: Sofa deletes it before every start and never restores (prepareProfile);
        //   write the one-tab session rarely instead of every 15 s, no closed-tab/window history
        @"browser.sessionstore.interval": @3600000, @"browser.sessionstore.max_tabs_undo": @0,
        @"browser.sessionstore.max_windows_undo": @0,
        // - the profile backup service (periodic backups of the whole profile; it fails here on
        //   the Documents folder anyway, measured 2026-11-17)
        @"browser.backup.enabled": @NO, @"browser.backup.scheduled.enabled": @NO,
        // shared SQLite locking instead of exclusive: Sofa copies the databases of the RAM profile
        // to the disk profile while the browser runs (SQLite backup API, SFYTRamProfile); browser
        // side only, nothing a page sees
        @"storage.sqlite.exclusiveLock.enabled": @NO,
    };
}

NSString *SFYTUserJS(NSDictionary *prefs) {
    NSMutableString *s = [NSMutableString stringWithString:@"// written by Sofa on every engine start (SFYTBrowser.m)\n"];
    for (NSString *k in [prefs.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSData *v = [NSJSONSerialization dataWithJSONObject:@[prefs[k]] options:0 error:nil];   // a JSON literal, unwrapped
        NSString *lit = [[NSString alloc] initWithData:v encoding:NSUTF8StringEncoding];
        [s appendFormat:@"user_pref(\"%@\", %@);\n", k, [lit substringWithRange:NSMakeRange(1, lit.length - 2)]];
    }
    return s;
}
