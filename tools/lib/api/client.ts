// HTTP for tools/test-api: TLS to a dev instance on loopback with the test's own certificate (the
// name goes in SNI and Host, nothing is resolved), plain HTTP on the same port. Every exchange is
// handed to a listener (the contract check) before the caller sees it.

import { request as https } from 'node:https';
import { request as http, type IncomingHttpHeaders } from 'node:http';
import type { Exchange } from './openapi.ts';

export interface Answer { status: number; headers: Record<string, string>; body: Buffer; json: any }   // eslint-disable-line @typescript-eslint/no-explicit-any

export interface Call {
  method?: string; path: string; token?: string; json?: unknown; text?: string; headers?: Record<string, string>; plain?: boolean;
  timeoutMs?: number;
  offContract?: boolean;   // a request outside the contract on purpose (an unknown route): not checked
  invalid?: boolean;       // a request body the contract refuses, on purpose: only the answer is checked
}

export class Client {
  private readonly name: string;
  private readonly port: number;
  private readonly ca: string;
  private readonly onExchange: (x: Exchange) => void;
  constructor(name: string, port: number, ca: string, onExchange: (x: Exchange) => void) {
    this.name = name; this.port = port; this.ca = ca; this.onExchange = onExchange;
  }

  async call(c: Call): Promise<Answer> {
    const method = c.method ?? (c.json !== undefined || c.text !== undefined ? 'POST' : 'GET');
    const headers: Record<string, string> = { Host: `${this.name}:${this.port}`, ...(c.headers ?? {}) };
    if (c.token) headers['Authorization'] = `Bearer ${c.token}`;
    let payload: Buffer | undefined;
    if (c.json !== undefined) { payload = Buffer.from(JSON.stringify(c.json)); headers['Content-Type'] = 'application/json'; }
    if (c.text !== undefined) { payload = Buffer.from(c.text); headers['Content-Type'] = 'text/plain'; }
    if (payload) headers['Content-Length'] = String(payload.length);
    const opts = { host: '127.0.0.1', port: this.port, method, path: c.path, headers, timeout: c.timeoutMs ?? 60_000 };
    const answer = await new Promise<Answer>((resolve, reject) => {
      const done = (res: { statusCode?: number; headers: IncomingHttpHeaders; on: (e: string, f: (x?: unknown) => void) => void }): void => {
        const chunks: Buffer[] = [];
        res.on('data', (d) => chunks.push(d as Buffer));
        res.on('end', () => {
          const body = Buffer.concat(chunks), h: Record<string, string> = {};
          for (const [k, v] of Object.entries(res.headers)) if (v !== undefined) h[k.toLowerCase()] = Array.isArray(v) ? v.join(', ') : v;
          let json: unknown = undefined;
          if ((h['content-type'] ?? '').startsWith('application/json')) { try { json = JSON.parse(body.toString('utf8')); } catch { json = undefined; } }
          resolve({ status: res.statusCode ?? 0, headers: h, body, json });
        });
      };
      const req = c.plain ? http(opts, done) : https({ ...opts, servername: this.name, ca: this.ca }, done);
      req.on('timeout', () => req.destroy(new Error(`${method} ${c.path}: timed out`)));
      req.on('error', reject);
      if (payload) req.write(payload);
      req.end();
    });
    const u = new URL(c.path, 'https://x');
    const reqHeaders: Record<string, string> = {};
    for (const [k, v] of Object.entries(c.headers ?? {})) reqHeaders[k.toLowerCase()] = v;
    if (c.offContract) return answer;
    this.onExchange({
      method, path: u.pathname, query: Object.fromEntries(u.searchParams), headers: reqHeaders,
      ...(c.invalid ? { invalidRequest: true } : {}),
      ...(c.json !== undefined ? { body: c.json, bodyType: 'application/json' } : c.text !== undefined ? { body: c.text, bodyType: 'text/plain' } : {}),
      status: answer.status, contentType: answer.headers['content-type'] ?? '', responseHeaders: answer.headers, responseBody: answer.body,
    });
    return answer;
  }
}
