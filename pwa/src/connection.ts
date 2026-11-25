// Where Sofa is and how this device proves itself: the full tailnet name (learned from the connect
// redirect, docs/pwa.md §1) and the device token from pairing. Kept in localStorage, per device.

export const PORT = 7443;

export interface Connection { host: string; token?: string }

const KEY = 'sofa.connection';

function storage(): Storage | null {
  try { return globalThis.localStorage ?? null; } catch { return null; }
}

export function loadConnection(): Connection | null {
  try {
    const raw = storage()?.getItem(KEY);
    if (!raw) return null;
    const c = JSON.parse(raw) as Partial<Connection>;
    return typeof c.host === 'string' && c.host ? { host: c.host, ...(typeof c.token === 'string' ? { token: c.token } : {}) } : null;
  } catch { return null; }
}

export function saveConnection(c: Connection | null): void {
  try {
    if (c) storage()?.setItem(KEY, JSON.stringify(c)); else storage()?.removeItem(KEY);
  } catch { /* private mode: the connection lasts this visit */ }
}

// What the user typed: "imac", "imac:7443", "https://imac.example.ts-net/" ... -> host[:port], or
// null for something that is no host name.
export function normalizeHost(input: string): string | null {
  let s = input.trim().toLowerCase();
  s = s.replace(/^[a-z]+:\/\//, '').replace(/\/.*$/, '');
  if (!s) return null;
  const m = /^([a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*)(:(\d{1,5}))?$/.exec(s);
  if (!m) return null;
  const port = m[6] ? Number(m[6]) : PORT;
  if (port < 1 || port > 65535) return null;
  return `${m[1]}:${port}`;
}

// A short name ("imac") can't carry TLS - the certificate is for the full MagicDNS name. The plain
// HTTP connect route on the same port tells it (a top-level navigation is allowed where a fetch
// would be mixed content).
export function needsDiscovery(host: string): boolean {
  return !host.split(':')[0]!.includes('.');
}

export function discoveryURL(host: string, returnURL: string): string {
  return `http://${host}/connect?return=${encodeURIComponent(returnURL)}`;
}

// "#host=<name>:<port>" from the connect redirect (or a shared link); null when absent or invalid.
export function hostFromHash(hash: string): string | null {
  const m = /(?:^#|&)host=([^&]+)/.exec(hash);
  if (!m) return null;
  try { return normalizeHost(decodeURIComponent(m[1]!)); } catch { return null; }
}

export function baseURL(c: Connection): string { return `https://${c.host}`; }

// The name to show: the machine's part of the host
export function shortName(host: string): string { return host.split(':')[0]!.split('.')[0]!; }
