// The one browser identity Sofa shows YouTube (docs/youtube.md "One identity"): a current desktop
// Chrome on a Mac in Austria, the same in every request of this process - InnerTube calls (pages
// for the app, player requests), BotGuard/WebPO, captions. A person's browser also keeps YouTube's
// cookies (YSC, VISITOR_INFO1_LIVE, ...) and sends them back; so does this one (cookie jar in the
// state directory, never logged).
//
// User agent: Chrome's own reduced format (macOS always "10_15_7", version "<major>.0.0.0") with
// the matching low-entropy client hints Chrome sends on every HTTPS request. The major version is
// the current stable one from Chrome's public version history (refreshed weekly) - a stale or
// truncated user agent is a classic bot signal (until 2026-11-06 it was bgutils' "...AppleWebKit/
// 537.36(KHTML, like Gecko)" without a browser version).
import fs from 'node:fs';
import path from 'node:path';
import { errorMessage } from './errors.ts';
import { log } from './log.ts';

export const LANG = 'de';
export const LOCATION = 'AT';
export const TIMEZONE = 'Europe/Vienna';
export const ACCEPT_LANGUAGE = 'de-AT,de;q=0.9,en;q=0.8';

const VERSION_URL = 'https://versionhistory.googleapis.com/v1/chrome/platforms/mac/channels/stable/versions?pageSize=1';
const REFRESH_MS = 7 * 24 * 3600 * 1000;
// last resort when the version history was never reachable: stable Chrome when this was written
const FALLBACK_MAJOR = 142;

export interface Identity {
  chromeMajor: number;
  userAgent: string;
  /** headers a Chrome page on youtube.com sends with every request (besides cookies) */
  headers: Record<string, string>;
}

export function identityFor(major: number): Identity {
  const ua = `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${major}.0.0.0 Safari/537.36`;
  return {
    chromeMajor: major,
    userAgent: ua,
    headers: {
      'user-agent': ua,
      'accept-language': ACCEPT_LANGUAGE,
      'sec-ch-ua': `"Chromium";v="${major}", "Google Chrome";v="${major}", "Not_A Brand";v="99"`,
      'sec-ch-ua-mobile': '?0',
      'sec-ch-ua-platform': '"macOS"',
    },
  };
}

/** The current stable Chrome major from the version history: {"versions":[{"version":"142.0.7444.60"}]} */
export function majorFromVersionHistory(body: unknown): number | null {
  const v = (body as { versions?: { version?: unknown }[] } | null)?.versions?.[0]?.version;
  const m = typeof v === 'string' ? /^(\d+)\./.exec(v) : null;
  const n = m ? Number(m[1]) : NaN;
  return n >= 100 && n < 1000 ? n : null;
}

/** Identity with the stable Chrome version, cached in <stateDir>/identity.json for a week. */
export async function loadIdentity(stateDir: string, fetchFn: typeof fetch = fetch): Promise<Identity> {
  const file = path.join(stateDir, 'identity.json');
  let cached: { major?: number; at?: number } = {};
  try { cached = JSON.parse(fs.readFileSync(file, 'utf8')) as typeof cached; } catch { /* first run */ }
  if (cached.major && cached.at && Date.now() - cached.at < REFRESH_MS) return identityFor(cached.major);
  try {
    // asked as the browser it will be (the last known version), not as node
    const r = await fetchFn(VERSION_URL, { headers: identityFor(cached.major ?? FALLBACK_MAJOR).headers, signal: AbortSignal.timeout(10000) });
    const major = r.ok ? majorFromVersionHistory(await r.json()) : null;
    if (!major) throw new Error(`no version in answer (HTTP ${r.status})`);
    fs.writeFileSync(file, JSON.stringify({ major, at: Date.now() }));
    if (major !== cached.major) log(`identity: Chrome ${major}`);
    return identityFor(major);
  } catch (e) {
    log(`identity: Chrome version unknown (${errorMessage(e)}), using ${cached.major ?? FALLBACK_MAJOR}`);
    return identityFor(cached.major ?? FALLBACK_MAJOR);
  }
}

// ---- cookies ---------------------------------------------------------------------------------

const YT_HOST = /(^|\.)youtube\.com$/;

/** YouTube's cookies as a browser keeps them: name -> value until expiry; only for youtube.com. */
export class CookieJar {
  file: string;
  cookies: Map<string, { value: string; expires: number }>;

  constructor(file: string) {
    this.file = file;
    this.cookies = new Map();
    try {
      const saved = JSON.parse(fs.readFileSync(file, 'utf8')) as Record<string, { value: string; expires: number }>;
      for (const [k, v] of Object.entries(saved)) if (v.expires > Date.now()) this.cookies.set(k, v);
    } catch { /* none yet */ }
  }

  header(host: string): string | null {
    if (!YT_HOST.test(host)) return null;
    const now = Date.now();
    const parts: string[] = [];
    for (const [k, v] of this.cookies) if (v.expires > now) parts.push(`${k}=${v.value}`);
    return parts.length ? parts.join('; ') : null;
  }

  /** Set-Cookie lines of an answer from `host` (session cookies live for the process: 1 day). */
  store(host: string, lines: string[]): void {
    if (!YT_HOST.test(host) || !lines.length) return;
    let changed = false;
    for (const line of lines) {
      const [pair, ...attrs] = line.split(';');
      const eq = pair?.indexOf('=') ?? -1;
      if (!pair || eq <= 0) continue;
      const name = pair.slice(0, eq).trim(), value = pair.slice(eq + 1).trim();
      let expires = Date.now() + 24 * 3600 * 1000;
      for (const a of attrs) {
        const [k, v] = a.split('=').map((s) => s.trim());
        if (k?.toLowerCase() === 'max-age' && v) expires = Date.now() + Number(v) * 1000;
        else if (k?.toLowerCase() === 'expires' && v && !attrs.some((x) => /max-age/i.test(x))) { const t = Date.parse(v); if (!isNaN(t)) expires = t; }
      }
      if (expires <= Date.now()) changed = this.cookies.delete(name) || changed;
      else { this.cookies.set(name, { value, expires }); changed = true; }
    }
    if (changed) {
      try { fs.writeFileSync(this.file, JSON.stringify(Object.fromEntries(this.cookies)), { mode: 0o600 }); }
      catch (e) { log('identity: cookies not saved:', errorMessage(e)); }
    }
  }
}

/**
 * fetch as the identity's browser: its headers on every request to YouTube/Google, YouTube's
 * cookies sent back and kept. Headers a caller sets explicitly (Range, content-type, x-goog-*)
 * stay; only the browser's own ones are taken from the identity.
 */
export function browserFetch(id: Identity, jar: CookieJar, base: typeof fetch = fetch): typeof fetch {
  const own = /(^|\.)(youtube\.com|googlevideo\.com|google\.com|googleapis\.com|ytimg\.com)$/;
  return (async (input: string | URL | Request, init?: RequestInit) => {
    const req = new Request(input, init);
    const host = new URL(req.url).hostname;
    if (!own.test(host)) return base(req);
    const h = new Headers(req.headers);
    for (const [k, v] of Object.entries(id.headers)) h.set(k, v);
    const c = jar.header(host);
    if (c) h.set('cookie', c); else h.delete('cookie');
    const res = await base(new Request(req, { headers: h }));
    jar.store(host, res.headers.getSetCookie());
    return res;
  }) as typeof fetch;
}
