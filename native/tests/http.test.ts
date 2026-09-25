import { describe, test, expect, beforeAll, afterAll } from 'bun:test';
import { readFileSync, rmSync } from 'node:fs';
import { createServer, type Server } from 'node:https';
import { resolve, join } from 'node:path';
import { capture, expectFixture, tempRoot } from './helpers.ts';

const dir = tempRoot('native-tls-');
const keyFile = join(dir, 'key.pem');
const certFile = join(dir, 'cert.pem');
const unreachableProxy = 'http://127.0.0.1:1';
let server: ReturnType<typeof Bun.serve>;
// Counts TLS handshakes, to observe pooled connection reuse.
let counting: Server;
let handshakes = 0;
const requests: { path: string; auth: string | null; body: string }[] = [];
const body = JSON.stringify({
  state: 'quotes " slashes \\ newline\n tab\t emoji 🙂; \\nurl = https://invalid.test/',
});

function selfSignedLocalhost() {
  const p = Bun.spawnSync([
    'openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
    '-keyout', keyFile, '-out', certFile, '-days', '1',
    '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost',
  ], { stdout: 'ignore', stderr: 'pipe' });
  expect(p.exitCode, p.stderr.toString()).toBe(0);
}

async function respond(req: Request) {
  const path = new URL(req.url).pathname;
  requests.push({ path, auth: req.headers.get('authorization'), body: await req.text() });
  if (path === '/redirect') {
    const location = `https://localhost:${server.port}/unexpected`;
    return new Response('', { status: 302, headers: { location } });
  }
  if (path === '/huge') return new Response('x'.repeat(1048577));
  if (path === '/error') return new Response('SYNTHETIC_NOT_A_SECRET', { status: 401 });
  if (path === '/slow') await Bun.sleep(2500);
  return new Response('ok');
}

beforeAll(() => {
  selfSignedLocalhost();
  expectFixture('http');
  server = Bun.serve({
    hostname: '127.0.0.1',
    port: 0,
    tls: { key: Bun.file(keyFile), cert: Bun.file(certFile) },
    fetch: respond,
  });
  const tls = { key: readFileSync(keyFile), cert: readFileSync(certFile) };
  counting = createServer(tls, (req, res) => {
    req.resume();
    req.on('end', () => res.end('ok'));
  });
  counting.on('secureConnection', () => handshakes++);
  return new Promise<void>(ready => counting.listen(0, '127.0.0.1', ready));
}, 100000);
afterAll(() => {
  server?.stop(true);
  counting?.close();
  rmSync(dir, { recursive: true, force: true });
});

interface Options {
  trust?: boolean;
  host?: string;
  input?: string;
  port?: number;
  repeat?: number;
  transport?: string;
}

async function post(path: string, options: Options = {}) {
  const { trust = true, host = 'localhost', input = body, port = server.port } = options;
  const url = `https://${host}:${port}${path}`;
  const env = {
    PATH: '/usr/bin:/bin',
    ...(trust ? { CURL_CA_BUNDLE: certFile } : {}),
    ...(options.transport === undefined ? {} : { JEV_FABRIC_HTTP: options.transport }),
    HTTPS_PROXY: unreachableProxy,
    ALL_PROXY: unreachableProxy,
  };
  const argv = [resolve('build/test-http'), '--', url, input];
  if (options.repeat !== undefined) argv.push(String(options.repeat));
  const { out, err, code } = await capture(argv, { env });
  expect(code, err).toBe(0);
  expect(out + err).not.toContain('SYNTHETIC_NOT_A_SECRET');
  return out.trim();
}

// Every policy test runs against the pooled libcurl transport, the curl
// executable, and the default (auto: pooled, falling back to the executable).
describe.each(['auto', 'pooled', 'exec'])('%s transport', transport => {
  const run = (path: string, options: Options = {}) => post(path, { ...options, transport });

  test('native HTTPS verifies trusted TLS and preserves private config/body literally', async () => {
    expect(await run('/ok')).toBe('ok:2');
    const req = requests.at(-1)!;
    expect(req.auth).toBe('Bearer SYNTHETIC_NOT_A_SECRET');
    expect(req.body).toBe(body);
  });

  test('unknown CA and wrong hostname fail closed', async () => {
    const n = requests.length;
    expect(await run('/untrusted', { trust: false })).toBe('error');
    expect(await run('/mismatch', { host: '127.0.0.1' })).toBe('error');
    expect(requests.length).toBe(n);
  });

  test('redirect is not followed and status errors never expose body', async () => {
    expect(await run('/redirect')).toBe('error');
    expect(requests.some(r => r.path === '/unexpected')).toBe(false);
    expect(await run('/error')).toBe('error');
  });

  test('body bounds and network deadline are enforced', async () => {
    expect(await run('/huge')).toBe('error');
    const start = Date.now();
    expect(await run('/slow')).toBe('error');
    expect(Date.now() - start).toBeLessThan(2300);
  });

  test('curl data-file syntax rejected before network', async () => {
    const n = requests.length;
    expect(await run('/file', { input: '@/etc/passwd' })).toBe('error');
    expect(requests.length).toBe(n);
  });
});

test('pooled transport reuses one TLS connection; exec pays a handshake per request', async () => {
  const port = (counting.address() as { port: number }).port;
  const replies = ['ok:2', 'ok:2', 'ok:2', 'ok:2'].join('\n');
  for (const [transport, expected] of [['pooled', 1], ['auto', 1], ['exec', 4]] as const) {
    handshakes = 0;
    expect(await post('/ok', { port, repeat: 4, transport })).toBe(replies);
    expect(handshakes).toBe(expected);
  }
});

test('an unknown transport fails closed before any network access', async () => {
  const n = requests.length;
  expect(await post('/ok', { transport: 'curl' })).toBe('error');
  expect(requests.length).toBe(n);
});
