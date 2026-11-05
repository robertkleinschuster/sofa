// Tiny JSON IPC client for mpv's --input-ipc-server (tests only).
import net from 'node:net';

/** One mpv IPC reply (`data` is whatever the property holds). */
export interface MpvReply {
  request_id?: number;
  error?: string;
  data?: unknown;
}

export interface MpvIpc {
  cmd(...command: (string | number)[]): Promise<MpvReply>;
  get(prop: string): Promise<unknown>;
  ready: Promise<unknown>;
  close(): void;
}

export function mpvIpc(sock: string): MpvIpc {
  let buf = ''; let id = 0;
  const pending = new Map<number, (m: MpvReply) => void>();
  const c = net.createConnection(sock);
  c.on('data', (d) => {
    buf += d;
    for (let i; (i = buf.indexOf('\n')) >= 0;) {
      const line = buf.slice(0, i); buf = buf.slice(i + 1);
      let m: MpvReply; try { m = JSON.parse(line) as MpvReply; } catch { continue; }
      const p = m.request_id ? pending.get(m.request_id) : undefined;
      if (p && m.request_id) { p(m); pending.delete(m.request_id); }
    }
  });
  c.on('error', () => {});
  const cmd = (...command: (string | number)[]): Promise<MpvReply> => new Promise((resolve, reject) => {
    const rid = ++id;
    const t = setTimeout(() => { pending.delete(rid); reject(new Error(`mpv ipc timeout: ${command}`)); }, 5000);
    pending.set(rid, (m) => { clearTimeout(t); resolve(m); });
    c.write(`${JSON.stringify({ command, request_id: rid })}\n`);
  });
  return {
    cmd,
    /** Property value, or null when unavailable / mpv busy (never throws). */
    async get(prop) { try { const m = await cmd('get_property', prop); return m.error === 'success' ? m.data : null; } catch { return null; } },
    ready: new Promise((r, j) => { c.once('connect', r); c.once('error', j); }),
    close: () => c.destroy(),
  };
}
